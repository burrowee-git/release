package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/burrowee-git/release-kit/build"
	"github.com/burrowee-git/release-kit/checksum"
	"github.com/burrowee-git/release-kit/minisign"
	"github.com/burrowee-git/release-kit/sign"
	"github.com/burrowee-git/release-kit/vulncheck"

	"github.com/burrowee-git/release/internal/relconfig"
)

type Options struct {
	Component, OutDir, RepoDir, DispatcherDir string
	// SrcDir is the COMPONENT source worktree (e.g. cli/code/cli) — distinct
	// from RepoDir, which is the release repo holding versions/, inner/, and
	// tools/. Defaults to RepoDir when empty, so the fixture-based
	// orchestrate tests (which double one dir as both) keep working
	// unchanged.
	SrcDir                                 string
	ConsolePubHex, ConsoleURL, MinisignKey string
	// SkipGate bypasses the mandatory vulncheck.Gate. Set ONLY by the harness
	// (runHarness): release.sh --dry-run does not run the CVE gate, so gating on
	// one side of the payload diff would abort orchestrate before it builds and
	// make an apples-to-apples comparison impossible. The CVE gate is validated
	// separately (Task 3 fixture) and stays mandatory for real cuts — the zero
	// value (false) keeps `run` fail-closed.
	SkipGate bool
	// Apple selects the Developer-ID signer (selectSigner) for build.Compile and
	// gates darwin zips through Notarizer.Notarize after assembly. Zero value
	// (false) keeps the existing ad-hoc, non-notarized behavior.
	Apple bool
	// DryRun, when Apple is set, skips the real notarize submission (logs intent
	// instead) — a dry run's artifacts are throwaway and notarization is a real
	// Apple API call.
	DryRun bool
}

type Result struct {
	Stamp         string
	Zips          []string
	Sums, Minisig string
}

// buildOpts configures `rkit build` — the real release-cut entry point:
// output lands at <RepoDir>/dist/<stamp>/ (never an arbitrary --out), an
// optional version bump shells the proven tools/version.sh with a
// revert-on-failure/dry-run trap, and the CVE gate runs by DEFAULT (the
// opposite of harness's SkipGate, which exists only for release.sh parity).
type buildOpts struct {
	Component, RepoDir, SrcDir, DispatcherDir, SignKey string
	Apple, DryRun, NoVulncheck                         bool
	// Bump is "", "patch", "minor", or "major" — the tools/version.sh
	// --bump-<kind> action to run before stamping. Empty means no bump.
	Bump string
}

func runBuild(args []string) error {
	fs := flag.NewFlagSet("build", flag.ContinueOnError)
	var o buildOpts
	fs.StringVar(&o.Component, "component", "", "cli|gateway|edge|agent")
	fs.StringVar(&o.RepoDir, "repo", ".", "release repo worktree")
	fs.StringVar(&o.SrcDir, "src", "", "component source worktree (default: resolved from BURROWEE_SRC_<COMP>/BB)")
	fs.StringVar(&o.DispatcherDir, "dispatcher", "", "dispatcher source worktree (default: resolved from BURROWEE_SRC_DISPATCHER/BB)")
	fs.StringVar(&o.SignKey, "sign-key", "", "minisign secret key (required for a real cut; --dry-run defaults to the TEST key)")
	appleFlag := fs.Bool("apple", false, "Developer-ID sign + notarize macOS binaries")
	publicFlag := fs.Bool("public", false, "public release: apple sign+notarize + CVE gate (standard ship path)")
	publicReleaseFlag := fs.Bool("public-release", false, "alias for --public")
	fs.BoolVar(&o.DryRun, "dry-run", false, "build without bumping the version or requiring a real sign key")
	fs.BoolVar(&o.NoVulncheck, "no-vulncheck", false, "skip the CVE gate (default: the gate runs)")
	bumpPatch := fs.Bool("bump-patch", false, "bump the component's patch version before building")
	bumpMinor := fs.Bool("bump-minor", false, "bump the component's minor version before building (prompts unless BURROWEE_RELEASE_YES=1)")
	bumpMajor := fs.Bool("bump-major", false, "bump the component's major version before building (prompts unless BURROWEE_RELEASE_YES=1)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	// --public / --public-release is the standard ship path: Apple sign+notarize + CVE gate.
	if *publicFlag || *publicReleaseFlag {
		o.Apple = true
		o.NoVulncheck = false
	}
	if *appleFlag {
		o.Apple = true
	}
	if (*bumpPatch && *bumpMinor) || (*bumpPatch && *bumpMajor) || (*bumpMinor && *bumpMajor) {
		return fmt.Errorf("only one of --bump-patch|--bump-minor|--bump-major may be set")
	}
	switch {
	case *bumpPatch:
		o.Bump = "patch"
	case *bumpMinor:
		o.Bump = "minor"
	case *bumpMajor:
		o.Bump = "major"
	}
	resolveComponentDirs(&o)
	if o.Apple {
		loadAppleAccount(o.RepoDir)
	}
	return buildRun(o)
}

// resolveComponentDirs fills SrcDir/DispatcherDir from the standard
// BURROWEE_SRC_<COMP>/BB locations (the same resolver the harness uses) unless
// --src/--dispatcher already set them. A real component's source lives in its
// OWN repo worktree (e.g. cli/code/cli), distinct from --repo (the release repo
// that holds versions/ + inner/ + tools/); without this, SrcDir would fall back
// to --repo in buildRun and rkit would try to build the component from the
// release repo.
func resolveComponentDirs(o *buildOpts) {
	if o.SrcDir != "" && o.DispatcherDir != "" {
		return
	}
	srcs, dispatcherDir := srcDirsForRepo()
	if o.SrcDir == "" {
		o.SrcDir = srcs[o.Component]
	}
	if o.DispatcherDir == "" {
		o.DispatcherDir = dispatcherDir
	}
}

// buildRun is the testable seam behind runBuild. It resolves dirs, optionally
// bumps the component's version (registering a revert that fires on error or
// --dry-run), runs the CVE gate unless NoVulncheck, then reuses orchestrate to
// build+assemble+checksum+sign into <RepoDir>/dist/<stamp>/.

// loadAppleAccount sets APPLE_ACCOUNT / APPLE_ACCOUNT_DIR from config/apple-account
// when --apple/--public is set so modernech-sign picks the project account plugin.
func loadAppleAccount(repoDir string) {
	if os.Getenv("APPLE_ACCOUNT_DIR") != "" || os.Getenv("APPLE_ACCOUNT") != "" {
		return
	}
	for _, name := range []string{"config/apple-account", "config/apple.account"} {
		b, err := os.ReadFile(filepath.Join(repoDir, name))
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(b), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			_ = os.Setenv("APPLE_ACCOUNT", line)
			home := os.Getenv("APPLE_HOME")
			if home == "" {
				home = filepath.Join(os.Getenv("HOME"), "Workstation", "Apple")
			}
			_ = os.Setenv("APPLE_ACCOUNT_DIR", filepath.Join(home, line))
			fmt.Fprintf(os.Stderr, "→ Apple account: %s\n", line)
			return
		}
	}
}

func buildRun(o buildOpts) (err error) {
	if o.DispatcherDir == "" {
		o.DispatcherDir = o.RepoDir
	}
	if o.SrcDir == "" {
		o.SrcDir = o.RepoDir
	}

	// Fail fast: a real cut requires a real sign key. Check this before the
	// bump + CVE gate so a doomed real cut doesn't waste either of them.
	// --dry-run defaults to the TEST key further down, where it's used.
	if !o.DryRun && o.SignKey == "" {
		return fmt.Errorf("--sign-key is required for a real build (only --dry-run defaults to the test key)")
	}
	if !o.DryRun {
		if _, err := os.Stat(o.SignKey); err != nil {
			return fmt.Errorf("--sign-key %s: %w", o.SignKey, err)
		}
	}

	// Revert the version bump if the build fails, or unconditionally on
	// --dry-run — a dry run must never leave a bumped versions/<comp> behind.
	// Registered BEFORE the bump step below so it also covers the bump
	// step's own failure (version.sh writes the file then `git add` fails).
	defer func() {
		if err != nil || o.DryRun {
			exec.Command("git", "-C", o.RepoDir, "restore", "--staged", "--worktree", "versions/"+o.Component).Run()
		}
	}()

	if !o.DryRun && o.Bump != "" {
		cmd := exec.Command("bash", filepath.Join(o.RepoDir, "tools", "version.sh"), o.Component, "--bump-"+o.Bump)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("version bump: %w", err)
		}
	}

	ctx := context.Background()
	stamp, err := relconfig.Stamp(ctx, filepath.Join(o.RepoDir, "versions", o.Component), o.SrcDir)
	if err != nil {
		return err
	}
	distDir := filepath.Join(o.RepoDir, "dist", stamp)

	// CVE gate — ON BY DEFAULT for a real build (unlike harness, which
	// SkipGates for release.sh --dry-run parity). --no-vulncheck bypasses it.
	if !o.NoVulncheck {
		if err = vulncheck.Gate(ctx, []vulncheck.Module{{Name: o.Component, Dir: o.SrcDir}},
			vulncheck.GateOpts{ReportDir: filepath.Join(distDir, "vulncheck")}); err != nil {
			return fmt.Errorf("cve gate: %w", err)
		}
	}

	key := o.SignKey
	if key == "" {
		// Reached only when o.DryRun (the real-cut case already returned above).
		key = filepath.Join(o.RepoDir, "tools", "testkeys", "test.key")
	}

	_, err = orchestrate(ctx, Options{
		Component: o.Component, OutDir: filepath.Join(o.RepoDir, "dist"),
		RepoDir: o.RepoDir, SrcDir: o.SrcDir, DispatcherDir: o.DispatcherDir,
		MinisignKey: key,
		SkipGate:    true, // the gate above already ran (or was explicitly bypassed)
		Apple:       o.Apple, DryRun: o.DryRun,
	})
	return err
}

// selectSigner picks build.Compile's Signer: a real Developer-ID signature via
// the product's modernech-sign helper when --apple is set, otherwise the
// existing ad-hoc codesign (macOS needs any signature to run, unsigned or
// ad-hoc, on non-apple/non-darwin cuts).
func selectSigner(apple bool) sign.Signer {
	if apple {
		return sign.AppleSigner{ToolPath: "modernech-sign"}
	}
	return sign.AdHocSigner{}
}

// notarizerFor returns the Notarizer to submit darwin zips to Apple when
// --apple is set, and whether notarization should run at all. Non-apple cuts
// never notarize.
func notarizerFor(apple bool) (sign.Notarizer, bool) {
	if apple {
		return sign.Notarizer{ToolPath: "modernech-sign"}, true
	}
	return sign.Notarizer{}, false
}

func orchestrate(ctx context.Context, o Options) (*Result, error) {
	if o.DispatcherDir == "" {
		o.DispatcherDir = o.RepoDir
	}
	if o.SrcDir == "" {
		o.SrcDir = o.RepoDir
	}
	// 1. CVE gate (fail-closed) — scan the component module. Skipped only under
	//    harness parity (o.SkipGate): release.sh --dry-run does not gate, so the
	//    CVE gate is validated separately and stays mandatory for real cuts.
	if !o.SkipGate {
		if err := vulncheck.Gate(ctx, []vulncheck.Module{{Name: o.Component, Dir: o.SrcDir}},
			vulncheck.GateOpts{ReportDir: filepath.Join(o.OutDir, "vulncheck")}); err != nil {
			return nil, fmt.Errorf("cve gate: %w", err)
		}
	}
	// 2. Stamp (read-only, no bump).
	stamp, err := relconfig.Stamp(ctx, filepath.Join(o.RepoDir, "versions", o.Component), o.SrcDir)
	if err != nil {
		return nil, err
	}
	// 3. Build component matrix.
	consolePubHex, err := resolveConsolePubHex(o)
	if err != nil {
		return nil, err
	}
	bins, err := relconfig.Bins(o.Component, stamp, consolePubHex, o.ConsoleURL)
	if err != nil {
		return nil, err
	}
	arts, err := build.Compile(ctx, build.Spec{
		SrcDir: o.SrcDir, OutDir: filepath.Join(o.OutDir, stamp),
		Targets: relconfig.Targets(), Bins: bins, Signer: selectSigner(o.Apple),
	})
	if err != nil {
		return nil, fmt.Errorf("compile %s: %w", o.Component, err)
	}
	res := &Result{Stamp: stamp}

	// 4. Build the dispatcher matrix — bundled into every component zip, stamped
	//    independently of the component (mirrors tools/release.sh's DISP_STAMP:
	//    versions/burrowee + the dispatcher source worktree).
	dispStamp, err := relconfig.Stamp(ctx, filepath.Join(o.RepoDir, "versions", "burrowee"), o.DispatcherDir)
	if err != nil {
		return nil, fmt.Errorf("dispatcher stamp: %w", err)
	}
	dispBins, err := relconfig.Bins("burrowee", dispStamp, "", "")
	if err != nil {
		return nil, fmt.Errorf("dispatcher bins: %w", err)
	}
	dispArts, err := build.Compile(ctx, build.Spec{
		SrcDir: o.DispatcherDir, OutDir: filepath.Join(o.OutDir, ".dispatcher", dispStamp),
		Targets: relconfig.Targets(), Bins: dispBins, Signer: selectSigner(o.Apple),
	})
	if err != nil {
		return nil, fmt.Errorf("compile dispatcher: %w", err)
	}

	// 5. install.sh is a static, verbatim per-component file — NOT
	//    rendered/templated. For cli/gateway/edge/agent it's inner/<comp>/install.sh
	//    (release.sh line 719); relay has NO inner/ entry — its install.sh is copied
	//    from the RELAY SOURCE worktree instead (release.sh line 558-560). Copy it
	//    out with the exec bit set, since the checked-in file isn't executable
	//    (tools/release.sh does the same `cp ... && chmod 0755` before zipping).
	installSrc := filepath.Join(o.RepoDir, "inner", o.Component, "install.sh")
	if o.Component == "relay" {
		installSrc = filepath.Join(o.SrcDir, "install.sh")
	}
	installSh := filepath.Join(o.OutDir, stamp, "install.sh")
	if err := copyExecutable(installSrc, installSh); err != nil {
		return nil, fmt.Errorf("install.sh: %w", err)
	}

	// 5b. Component-specific extra payload files beyond bins+dispatcher+install.sh.
	extras, err := extraPayload(o.Component, o.SrcDir)
	if err != nil {
		return nil, fmt.Errorf("extra payload: %w", err)
	}

	// 6. Assemble one flat zip per target: component bins + dispatcher + install.sh
	//    + any component extras (update scripts, edge covers).
	zips, err := assemble(o.Component, stamp, o.OutDir, installSh, extras, arts, dispArts)
	if err != nil {
		return nil, fmt.Errorf("assemble: %w", err)
	}
	res.Zips = zips

	// 6b. Notarize darwin zips when --apple is set. Notarization submits the
	//     zip to Apple for review; it does NOT alter zip bytes (bare-binary
	//     zips aren't stapled — the ticket lives in Apple's online DB, checked
	//     at gatekeeper-assess time). --dry-run skips the real submission
	//     (logs intent) since dry-run artifacts are throwaway and notarizing
	//     is a real, rate-limited Apple API call.
	if n, do := notarizerFor(o.Apple); do {
		for _, zp := range res.Zips {
			if !strings.Contains(filepath.Base(zp), "-darwin-") {
				continue
			}
			if o.DryRun {
				fmt.Fprintf(os.Stderr, "dry-run: skipping notarize of %s\n", zp)
				continue
			}
			if err := n.Notarize(ctx, zp); err != nil {
				return nil, fmt.Errorf("notarize %s: %w", zp, err)
			}
		}
	}

	// 7. Checksum + sign the assembled zips. Per-target zip names are unique
	//    (unlike the raw artifacts, where every target ships the same bin
	//    basenames), so WriteSums's duplicate-basename guard never trips here.
	sums := filepath.Join(o.OutDir, stamp, "SHA256SUMS.txt")
	if err := checksum.WriteSums(res.Zips, sums); err != nil {
		return nil, fmt.Errorf("checksum: %w", err)
	}
	key := o.MinisignKey
	if key == "" {
		key = filepath.Join(o.RepoDir, "tools", "testkeys", "test.key")
	}
	if _, statErr := os.Stat(key); statErr == nil {
		if err := minisign.Sign(ctx, sums, key); err != nil {
			return nil, fmt.Errorf("minisign: %w", err)
		}
		res.Minisig = sums + ".minisig"
	}
	res.Sums = sums
	return res, nil
}

// copyExecutable copies src to dst with mode 0755. install.sh ships in the
// repo without its exec bit set (git doesn't track it); the assembled zip
// needs it — tools/release.sh does the same `cp` + `chmod 0755`.
func copyExecutable(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o755)
}

// placeholderConsolePubHex is the dead-key placeholder shipped in
// config/console-pub.hex templates: valid-length hex a runtime check can't
// distinguish from a real key. Mirrors tools/build.sh's edge/relay guard.
const placeholderConsolePubHex = "0000000000000000000000000000000000000000000000000000000000000000"

// resolveConsolePubHex returns the console signing pubkey hex for edge/relay
// builds. An explicit Options.ConsolePubHex wins; otherwise it reads
// config/console-pub.hex under RepoDir (skipping comment/blank lines, same
// parsing as tools/release.sh's console_pub_hex()). A missing config file
// resolves to "" with no error — components that don't need a console key
// (cli/gateway/agent/burrowee) never hit this file. Either way, the resolved
// value is rejected if it's the 64-zero placeholder.
func resolveConsolePubHex(o Options) (string, error) {
	hex := o.ConsolePubHex
	if hex == "" {
		path := filepath.Join(o.RepoDir, "config", "console-pub.hex")
		raw, err := os.ReadFile(path)
		if err != nil {
			if os.IsNotExist(err) {
				return "", nil
			}
			return "", fmt.Errorf("read %s: %w", path, err)
		}
		for _, line := range strings.Split(string(raw), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			hex = line
			break
		}
	}
	if hex == placeholderConsolePubHex {
		return "", fmt.Errorf("console pubkey is the placeholder — set config/console-pub.hex to the real console signing key before an edge/relay release")
	}
	return hex, nil
}
