package main

import (
	"context"
	"flag"
	"fmt"
	"os"
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
}

type Result struct {
	Stamp         string
	Zips          []string
	Sums, Minisig string
}

func runOrchestrate(args []string) error {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	var o Options
	fs.StringVar(&o.Component, "component", "", "cli|gateway|edge|agent|relay|burrowee")
	fs.StringVar(&o.OutDir, "out", "", "scratch output dir")
	fs.StringVar(&o.RepoDir, "repo", ".", "release repo worktree")
	fs.StringVar(&o.DispatcherDir, "dispatcher", "", "dispatcher source worktree (defaults to repo)")
	fs.StringVar(&o.MinisignKey, "key", "", "minisign secret key (defaults to TEST key)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	// defaults resolved in orchestrate(): console keys from config/console-pub.hex, key from tools/testkeys.
	_, err := orchestrate(context.Background(), o)
	return err
}

func orchestrate(ctx context.Context, o Options) (*Result, error) {
	if o.DispatcherDir == "" {
		o.DispatcherDir = o.RepoDir
	}
	if o.SrcDir == "" {
		o.SrcDir = o.RepoDir
	}
	// 1. CVE gate (fail-closed) — scan the component module.
	if err := vulncheck.Gate(ctx, []vulncheck.Module{{Name: o.Component, Dir: o.SrcDir}},
		vulncheck.GateOpts{ReportDir: filepath.Join(o.OutDir, "vulncheck")}); err != nil {
		return nil, fmt.Errorf("cve gate: %w", err)
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
		Targets: relconfig.Targets(), Bins: bins, Signer: sign.AdHocSigner{},
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
		Targets: relconfig.Targets(), Bins: dispBins, Signer: sign.AdHocSigner{},
	})
	if err != nil {
		return nil, fmt.Errorf("compile dispatcher: %w", err)
	}

	// 5. install.sh is a static, verbatim per-component file (inner/<comp>/install.sh)
	//    — NOT rendered/templated. Copy it out with the exec bit set, since the
	//    checked-in file isn't executable (tools/release.sh does the same
	//    `cp ... && chmod 0755` before zipping).
	installSrc := filepath.Join(o.RepoDir, "inner", o.Component, "install.sh")
	installSh := filepath.Join(o.OutDir, stamp, "install.sh")
	if err := copyExecutable(installSrc, installSh); err != nil {
		return nil, fmt.Errorf("install.sh: %w", err)
	}

	// 6. Assemble one flat zip per target: component bins + dispatcher + install.sh.
	zips, err := assemble(o.Component, stamp, o.OutDir, installSh, arts, dispArts)
	if err != nil {
		return nil, fmt.Errorf("assemble: %w", err)
	}
	res.Zips = zips

	// 7. Checksum + sign the assembled zips. Per-target zip names are unique
	//    (unlike the raw artifacts, where every target ships the same bin
	//    basenames), so WriteSums's duplicate-basename guard never trips here.
	sums := filepath.Join(o.OutDir, stamp, "SHA256SUMS.txt")
	if err := checksum.WriteSums(res.Zips, sums); err != nil {
		return nil, fmt.Errorf("checksum: %w", err)
	}
	key := o.MinisignKey
	if key == "" {
		key = filepath.Join(o.RepoDir, "tools", "testkeys", "burrowee-release-test.key")
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
