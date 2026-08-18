package main

import (
	"archive/zip"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/burrowee-git/release-kit/sign"
	"github.com/burrowee-git/release/internal/relconfig"
)

func TestOrchestrateBuildsMatrixIntoScratch(t *testing.T) {
	// Minimal module fixture: one main package printing a version var.
	repo := t.TempDir()
	writeFixtureModule(t, repo) // helper below: go.mod + cmd/burrowee-cli/main.go + cmd/burrowee-cli-updater/main.go + versions/cli
	out := t.TempDir()
	ctx := context.Background()
	res, err := orchestrate(ctx, Options{
		Component: "cli", OutDir: out, RepoDir: repo,
		DispatcherDir: repo, // fixture doubles as dispatcher for the test
		MinisignKey:   testMinisignKey(t),
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Stamp == "" {
		t.Fatal("empty stamp")
	}
	// binaries for every target must exist.
	for _, tgt := range relconfig.Targets() {
		for _, b := range []string{"burrowee-cli", "burrowee-cli-updater"} {
			p := filepath.Join(out, res.Stamp, tgt.OS+"-"+tgt.Arch, b)
			if _, err := os.Stat(p); err != nil {
				t.Errorf("missing %s: %v", p, err)
			}
		}
	}
	// one assembled zip per target, containing exactly the component bins,
	// the burrowee dispatcher, and install.sh — nothing else.
	if len(res.Zips) != len(relconfig.Targets()) {
		t.Fatalf("got %d zips, want %d: %v", len(res.Zips), len(relconfig.Targets()), res.Zips)
	}
	// The migrations/ members are named EXPLICITLY, not globbed off the fixture:
	// this is the assertion that the ladder actually lands INSIDE the zip. The
	// defect it guards is not hypothetical — gateway v0.2.0.2026.08.07 was
	// signed, notarized and published with migrations/ staged and then dropped
	// on the floor by the packaging step, and nothing compared the two.
	wantEntries := []string{
		"burrowee", "burrowee-cli", "burrowee-cli-updater", "install.sh", "update.sh",
		"migrations/run.sh", "migrations/upgrade.sh", "migrations/lib_paths.sh",
		"migrations/lib_stale_user_bins.sh", "migrations/stale_user_bins.sh",
		"migrations/component.conf", "migrations/ledger",
	}
	sort.Strings(wantEntries)
	for _, zp := range res.Zips {
		r, err := zip.OpenReader(zp)
		if err != nil {
			t.Fatalf("open %s: %v", zp, err)
		}
		var got []string
		for _, f := range r.File {
			got = append(got, f.Name)
		}
		r.Close()
		sort.Strings(got)
		if !reflect.DeepEqual(got, wantEntries) {
			t.Errorf("%s entries = %v, want %v", zp, got, wantEntries)
		}
	}
	if _, err := os.Stat(res.Sums); err != nil {
		t.Errorf("missing sums file %s: %v", res.Sums, err)
	}
	if res.Minisig != "" {
		if _, err := os.Stat(res.Minisig); err != nil {
			t.Errorf("Result.Minisig=%s but file missing: %v", res.Minisig, err)
		}
	}
}

// writeFixtureModule creates a self-contained module (no external deps) with a
// trivial main package per binary (a stampable `var version string`) and a
// versions/cli semver file, then commits it so relconfig.Stamp's `git
// rev-parse` has a HEAD to read.
func writeFixtureModule(t *testing.T, repo string) {
	t.Helper()
	write := func(rel, content string) {
		full := filepath.Join(repo, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("go.mod", "module fixture\n\ngo 1.25.0\n")
	mainSrc := "package main\n\nimport \"fmt\"\n\nvar version string\n\nfunc main() { fmt.Println(version) }\n"
	write("cmd/burrowee-cli/main.go", mainSrc)
	write("cmd/burrowee-cli-updater/main.go", mainSrc)
	write("main.go", mainSrc) // root package "." — doubles as the dispatcher source
	write("versions/cli", "0.1.0\n")
	write("versions/burrowee", "0.1.0\n")
	write("inner/cli/install.sh", "#!/bin/sh\necho fixture-install\n")
	// cli ships update.sh (only) at its source root — core's Phase-0 routing
	// execs it on a non-force update. extraPayload requires it present.
	write("update.sh", "#!/bin/sh\necho fixture-update\n")
	// The SHARED migration ladder, which the cli takes. extraPayload stages the
	// runner + library + rungs out of the RELEASE repo and component.conf +
	// ledger out of the component source; in this fixture both roles are played
	// by the same directory, so the two halves land beside each other. Every one
	// is required — a kit missing any of them installs cleanly and silently
	// stops migrating, which is what the gate exists to make impossible.
	for _, f := range []string{"run.sh", "upgrade.sh", "lib_paths.sh", "lib_stale_user_bins.sh", "stale_user_bins.sh"} {
		write("inner/_shared/migrations/"+f, "#!/bin/sh\n: fixture "+f+"\n")
	}
	write("migrations/component.conf", "COMP=cli\nCOMP_HOME_SCHEME=user\n")
	write("migrations/ledger", "0.2.0 stale_user_bins.sh\n")

	git := func(args ...string) {
		t.Helper()
		c := exec.Command("git", append([]string{"-C", repo}, args...)...)
		c.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t",
			"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	git("init", "-q")
	git("add", "-A")
	git("commit", "-q", "-m", "fixture")
}

// testMinisignKey generates a password-less minisign secret key in a temp dir
// and returns its path. If minisign isn't installed, it returns "" — the
// os.Stat guard in orchestrate() then skips signing rather than failing the
// whole test on a missing binary.
func testMinisignKey(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("minisign"); err != nil {
		t.Log("minisign not installed — signing portion will be skipped")
		return ""
	}
	dir := t.TempDir()
	pub := filepath.Join(dir, "key.pub")
	sec := filepath.Join(dir, "key.sec")
	if out, err := exec.Command("minisign", "-G", "-W", "-p", pub, "-s", sec).CombinedOutput(); err != nil {
		t.Fatalf("minisign keygen: %v\n%s", err, out)
	}
	return sec
}

// TestOrchestrateSkipGateBypassesCVEGate proves Options.SkipGate short-circuits
// the mandatory vulncheck.Gate. To make a real gate call deterministically fail
// regardless of host state, GOPATH is repointed at an empty dir: govulncheck is
// installed under the real GOPATH/bin (and is NOT on PATH), so
// resolveGovulncheck can't find it and Gate returns "govulncheck not found".
// The fixture module is stdlib-only, so the empty GOPATH doesn't affect the
// build itself.
func TestOrchestrateSkipGateBypassesCVEGate(t *testing.T) {
	t.Setenv("GOPATH", t.TempDir())
	repo := t.TempDir()
	writeFixtureModule(t, repo)
	ctx := context.Background()
	key := testMinisignKey(t)

	// Gate ON (SkipGate zero value): orchestrate must abort at the CVE gate.
	if _, err := orchestrate(ctx, Options{
		Component: "cli", OutDir: t.TempDir(), RepoDir: repo,
		DispatcherDir: repo, MinisignKey: key,
	}); err == nil || !strings.Contains(err.Error(), "cve gate") {
		t.Fatalf("gate ON: want a cve gate error, got %v", err)
	}

	// Gate SKIPPED: the same build now succeeds past the gate.
	if _, err := orchestrate(ctx, Options{
		Component: "cli", OutDir: t.TempDir(), RepoDir: repo,
		DispatcherDir: repo, MinisignKey: key, SkipGate: true,
	}); err != nil {
		t.Fatalf("gate SKIPPED: orchestrate should bypass the gate and succeed, got %v", err)
	}
}

func TestBuildWritesToDistStamp(t *testing.T) {
	repo := t.TempDir()
	writeFixtureModule(t, repo)
	// build with default gate SKIPPED for the fixture host (go1.26.0): pass --no-vulncheck.
	err := buildRun(buildOpts{Component: "cli", RepoDir: repo, SrcDir: repo, DispatcherDir: repo,
		NoVulncheck: true, SignKey: testMinisignKey(t)})
	if err != nil {
		t.Fatal(err)
	}
	// artifacts land under repo/dist/<stamp>/, NOT an arbitrary --out.
	stamp := mustStamp(t, repo, "cli")
	if _, err := os.Stat(filepath.Join(repo, "dist", stamp, "burrowee-cli-linux-amd64.zip")); err != nil {
		t.Errorf("missing zip under dist/<stamp>: %v", err)
	}
	if _, err := os.Stat(filepath.Join(repo, "dist", stamp, "SHA256SUMS.txt")); err != nil {
		t.Errorf("missing SHA256SUMS: %v", err)
	}
}

// TestBuildRunFailsFastOnMissingSignKeyFile proves a real cut (DryRun:false)
// with a --sign-key path that doesn't exist on disk fails IMMEDIATELY, before
// any build work runs — never silently skipping the sign step and reporting
// success. Pre-fix, buildRun only checked SignKey=="" and let a bad path
// reach orchestrate's `os.Stat(key)==nil` guard around minisign.Sign, which
// just skips signing and returns nil: this test is RED against that code and
// GREEN once buildRun stats the key file up front.
func TestBuildRunFailsFastOnMissingSignKeyFile(t *testing.T) {
	repo := t.TempDir()
	writeFixtureModule(t, repo)
	stamp := mustStamp(t, repo, "cli")

	err := buildRun(buildOpts{
		Component: "cli", RepoDir: repo, SrcDir: repo, DispatcherDir: repo,
		DryRun: false, SignKey: "/nonexistent/path/key.key", NoVulncheck: true,
	})
	if err == nil {
		t.Fatal("expected error for missing --sign-key file, got nil")
	}
	if !strings.Contains(err.Error(), "sign-key") || !strings.Contains(err.Error(), "no such file") {
		t.Fatalf("error = %q, want it to mention sign-key and no such file", err.Error())
	}
	// Fail-fast means no build work happened: no dist/<stamp> zips.
	if _, statErr := os.Stat(filepath.Join(repo, "dist", stamp)); !os.IsNotExist(statErr) {
		t.Fatalf("dist/%s should not exist (fail-fast before build), stat err = %v", stamp, statErr)
	}
}

// TestBuildRunBumpDryRunReverts exercises the bump+revert path end-to-end: a
// --bump-patch --dry-run build must run the revert (registered before the
// bump block, per the FIX 1 reorder) and leave versions/<comp> exactly as it
// was committed, with no staged or worktree diff left behind.
func TestBuildRunBumpDryRunReverts(t *testing.T) {
	repo := t.TempDir()
	writeFixtureModule(t, repo) // versions/cli = "0.1.0\n", committed
	if err := buildRun(buildOpts{
		Component: "cli", RepoDir: repo, SrcDir: repo, DispatcherDir: repo,
		Bump: "patch", DryRun: true, NoVulncheck: true, SignKey: testMinisignKey(t),
	}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(repo, "versions", "cli"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "0.1.0\n" {
		t.Fatalf("versions/cli = %q, want unchanged %q (revert did not fire)", got, "0.1.0\n")
	}
	out, err := exec.Command("git", "-C", repo, "status", "--porcelain", "versions/cli").CombinedOutput()
	if err != nil {
		t.Fatalf("git status: %v\n%s", err, out)
	}
	if strings.TrimSpace(string(out)) != "" {
		t.Fatalf("git status --porcelain versions/cli = %q, want clean", out)
	}
}

func TestBuildGateOnByDefaultCanBeSkipped(t *testing.T) {
	// With NoVulncheck=false and no govulncheck resolvable, the gate must RUN
	// (and here fail) — proving default-on. Then NoVulncheck=true bypasses.
	repo := t.TempDir()
	writeFixtureModule(t, repo)
	t.Setenv("GOPATH", t.TempDir()) // make govulncheck unresolvable → gate errors
	if err := buildRun(buildOpts{Component: "cli", RepoDir: repo, SrcDir: repo, DispatcherDir: repo,
		NoVulncheck: false, SignKey: testMinisignKey(t)}); err == nil {
		t.Fatal("expected default-on gate to run and fail")
	}
	if err := buildRun(buildOpts{Component: "cli", RepoDir: repo, SrcDir: repo, DispatcherDir: repo,
		NoVulncheck: true, SignKey: testMinisignKey(t)}); err != nil {
		t.Fatalf("--no-vulncheck should bypass: %v", err)
	}
}

// mustStamp computes the expected dist/<stamp> directory name the same way
// buildRun/orchestrate do, so tests can assert on artifact paths without
// duplicating the stamp scheme.
func mustStamp(t *testing.T, repo, comp string) string {
	t.Helper()
	stamp, err := relconfig.Stamp(context.Background(), filepath.Join(repo, "versions", comp), repo)
	if err != nil {
		t.Fatal(err)
	}
	return stamp
}

func TestBuildAppleSelectsDevIDSignerAndNotarizes(t *testing.T) {
	// Unit-level: assert selectSigner(apple=true) returns AppleSigner{ToolPath:"modernech-sign"}
	// and notarizerFor(apple=true) returns Notarizer{ToolPath:"modernech-sign"};
	// apple=false returns AdHocSigner and a nil/skip notarizer.
	s := selectSigner(true)
	if _, ok := s.(sign.AppleSigner); !ok {
		t.Fatalf("apple signer type = %T", s)
	}
	if got := s.(sign.AppleSigner).ToolPath; got != "modernech-sign" {
		t.Fatalf("toolpath %q", got)
	}
	if selectSigner(false) == nil {
		t.Fatal("adhoc signer nil")
	}
	if _, ok := selectSigner(false).(sign.AdHocSigner); !ok {
		t.Fatal("non-apple must be adhoc")
	}
	n, do := notarizerFor(true)
	if !do || n.ToolPath != "modernech-sign" {
		t.Fatalf("notarizer %+v do=%v", n, do)
	}
	if _, do2 := notarizerFor(false); do2 {
		t.Fatal("non-apple must not notarize")
	}
}

func TestOrchestrateRejectsPlaceholderConsolePubHex(t *testing.T) {
	placeholder := strings.Repeat("0", 64)

	if _, err := resolveConsolePubHex(Options{ConsolePubHex: placeholder}); err == nil {
		t.Fatal("expected error for placeholder ConsolePubHex, got nil")
	}

	repo := t.TempDir()
	if err := os.MkdirAll(filepath.Join(repo, "config"), 0o755); err != nil {
		t.Fatal(err)
	}
	content := "# comment line\n" + placeholder + "\n"
	if err := os.WriteFile(filepath.Join(repo, "config", "console-pub.hex"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := resolveConsolePubHex(Options{RepoDir: repo}); err == nil {
		t.Fatal("expected error reading placeholder from config/console-pub.hex")
	}

	// A real-looking key must pass through untouched.
	real := strings.Repeat("a", 64)
	got, err := resolveConsolePubHex(Options{ConsolePubHex: real})
	if err != nil {
		t.Fatalf("resolveConsolePubHex(real key): %v", err)
	}
	if got != real {
		t.Fatalf("resolveConsolePubHex(real key) = %q, want %q", got, real)
	}

	// No config file at all (e.g. cli component) resolves to "" with no error.
	emptyRepo := t.TempDir()
	got, err = resolveConsolePubHex(Options{RepoDir: emptyRepo})
	if err != nil {
		t.Fatalf("resolveConsolePubHex(no config file): %v", err)
	}
	if got != "" {
		t.Fatalf("resolveConsolePubHex(no config file) = %q, want empty", got)
	}
}

func TestResolveComponentDirs(t *testing.T) {
	// --src/--dispatcher already set → left untouched.
	o := buildOpts{Component: "cli", SrcDir: "/explicit/src", DispatcherDir: "/explicit/disp"}
	resolveComponentDirs(&o)
	if o.SrcDir != "/explicit/src" || o.DispatcherDir != "/explicit/disp" {
		t.Fatalf("explicit dirs overridden: %+v", o)
	}

	// Unset → resolved from BURROWEE_SRC_<COMP>/BURROWEE_SRC_DISPATCHER.
	t.Setenv("BURROWEE_SRC_CLI", "/env/cli/src")
	t.Setenv("BURROWEE_SRC_DISPATCHER", "/env/dispatcher")
	o2 := buildOpts{Component: "cli"}
	resolveComponentDirs(&o2)
	if o2.SrcDir != "/env/cli/src" {
		t.Fatalf("SrcDir = %q, want /env/cli/src", o2.SrcDir)
	}
	if o2.DispatcherDir != "/env/dispatcher" {
		t.Fatalf("DispatcherDir = %q, want /env/dispatcher", o2.DispatcherDir)
	}

	// The bug this fixes: a real component must resolve to its OWN source, never
	// fall back to the release repo (RepoDir).
	t.Setenv("BURROWEE_SRC_GATEWAY", "/env/gateway/src")
	o3 := buildOpts{Component: "gateway", RepoDir: "/release/repo"}
	resolveComponentDirs(&o3)
	if o3.SrcDir == "" || o3.SrcDir == o3.RepoDir {
		t.Fatalf("gateway SrcDir wrongly empty/==repo: %q", o3.SrcDir)
	}
}

// TestBuildRecordsCompStamp pins the bookkeeping half of a cut: a real build
// must write versions/<comp>.stamp, matching the stamp its artifacts were built
// under.
//
// This is not cosmetic. release.sh's resolve_comp_stamp reads that file and, when
// its recorded sha8 + semver still match the source, reuses the stamp verbatim
// instead of bumping — the no-op-cut freeze. rkit bumped versions/<comp> and never
// wrote the stamp, so the file stayed one release behind on every cut through this
// path (observed 2026-07-31: cli, gateway and relay all stale, cli reading v0.1.74
// after v0.1.75 shipped), the freeze could never engage, and the record claimed a
// release that had not shipped.
func TestBuildRecordsCompStamp(t *testing.T) {
	repo := t.TempDir()
	writeFixtureModule(t, repo)
	if err := buildRun(buildOpts{Component: "cli", RepoDir: repo, SrcDir: repo, DispatcherDir: repo,
		NoVulncheck: true, SignKey: testMinisignKey(t)}); err != nil {
		t.Fatal(err)
	}
	stamp := mustStamp(t, repo, "cli")
	got, err := os.ReadFile(filepath.Join(repo, "versions", "cli.stamp"))
	if err != nil {
		t.Fatalf("versions/cli.stamp not written: %v", err)
	}
	if strings.TrimSpace(string(got)) != stamp {
		t.Fatalf("versions/cli.stamp = %q, want the built stamp %q", strings.TrimSpace(string(got)), stamp)
	}
}

// TestBuildRelativeRepoWritesIntoReleaseRepoNotSource pins the flag's own default.
// `rkit build --repo .` (build.go:69) used RepoDir verbatim, so the derived
// OutDir stayed relative — and release-kit's build.Compile creates OutDir in the
// rkit process cwd while passing `-o <relative path>` to a `go build` whose
// cmd.Dir is SrcDir (release-kit build/build.go:77-92). The binaries therefore
// landed in the COMPONENT source worktree and the sign step, resolving the same
// relative path from rkit's cwd, failed with a message naming codesign.
//
// TWO directories are load-bearing here. Every other test in this file doubles
// one dir as repo and source, where a relative OutDir resolves to the same place
// either way and the bug is invisible.
func TestBuildRelativeRepoWritesIntoReleaseRepoNotSource(t *testing.T) {
	repo := t.TempDir() // the release repo: versions/, inner/, tools/
	src := t.TempDir()  // the component source worktree
	writeFixtureModule(t, repo)
	writeFixtureModule(t, src)

	t.Chdir(repo) // rkit is invoked from the release repo; --repo . means "here"

	if err := buildRun(buildOpts{
		Component: "cli", RepoDir: ".", SrcDir: src, DispatcherDir: src,
		NoVulncheck: true, SignKey: testMinisignKey(t),
	}); err != nil {
		t.Fatalf("buildRun(--repo .): %v", err)
	}

	// Anti-vacuity: the artifacts must actually be somewhere, or "nothing was
	// written into the source tree" passes for a build that produced nothing.
	//
	// Stamp from src, NOT repo. This is the only test in this file where the two
	// are different trees, and the stamp's sha8 comes from the COMPONENT source's
	// git HEAD (release-kit version.Stamp runs `git rev-parse` in SrcDir) — which
	// is what buildRun used to name dist/<stamp>. writeFixtureModule pins no
	// GIT_AUTHOR_DATE, so the two fixtures' commits share a SHA only when they
	// land in the same wall-clock second: stamping from repo passed locally and
	// then failed roughly whenever the pair straddled a second boundary. The
	// failure read "no zip under the RELEASE repo's dist/…", i.e. it impersonated
	// the very defect this test guards. Do not "simplify" this back to repo.
	stamp := mustStamp(t, src, "cli")
	if _, err := os.Stat(filepath.Join(repo, "dist", stamp, "burrowee-cli-linux-amd64.zip")); err != nil {
		t.Fatalf("no zip under the RELEASE repo's dist/%s: %v", stamp, err)
	}

	// The defect itself: nothing may be written into the component source tree.
	if _, err := os.Stat(filepath.Join(src, "dist")); !os.IsNotExist(err) {
		t.Errorf("dist/ exists in the COMPONENT source worktree %s (stat err = %v) — "+
			"a relative --repo must resolve against the release repo, not leak into the "+
			"tree being compiled", src, err)
	}
	out, err := exec.Command("git", "-C", src, "status", "--porcelain", "--untracked-files=all").CombinedOutput()
	if err != nil {
		t.Fatalf("git status in source tree: %v\n%s", err, out)
	}
	if strings.TrimSpace(string(out)) != "" {
		t.Errorf("the component source worktree is no longer clean:\n%s", out)
	}
}

// TestOrchestrateRejectsRelativePaths pins the fail-closed guard added at the
// top of orchestrate: every one of RepoDir/SrcDir/DispatcherDir/OutDir must be
// absolute, or orchestrate must refuse before touching the filesystem for
// anything beyond the check itself (no fixture module is written — a failing
// guard here has nothing else to blame the error on). An unreached guard is
// worth as little as no guard, so each field is exercised on its own so a
// broken check on one field can't hide behind the other three passing.
func TestOrchestrateRejectsRelativePaths(t *testing.T) {
	ctx := context.Background()
	abs := t.TempDir()
	base := Options{Component: "cli", OutDir: abs, RepoDir: abs, SrcDir: abs, DispatcherDir: abs}

	for _, field := range []string{"RepoDir", "SrcDir", "DispatcherDir", "OutDir"} {
		t.Run(field, func(t *testing.T) {
			o := base
			switch field {
			case "RepoDir":
				o.RepoDir = "relative"
			case "SrcDir":
				o.SrcDir = "relative"
			case "DispatcherDir":
				o.DispatcherDir = "relative"
			case "OutDir":
				o.OutDir = "relative"
			}
			_, err := orchestrate(ctx, o)
			if err == nil {
				t.Fatalf("orchestrate with relative %s: expected error, got nil", field)
			}
			if !strings.Contains(err.Error(), field+" must be absolute") {
				t.Fatalf("orchestrate with relative %s: err = %v, want mention of %q must be absolute",
					field, err, field)
			}
		})
	}
}

// TestBuildDryRunDoesNotRecordCompStamp is the other half of the contract, and
// the more dangerous direction: --dry-run publishes nothing, so a stamp left
// behind by one would be read by the NEXT unchanged-source cut as proof that
// version had already shipped — freezing a release that never existed. Mirrors
// the dispatcher's own dry-run guard in tools/test-dispatcher-stamp-freeze.sh (d).
func TestBuildDryRunDoesNotRecordCompStamp(t *testing.T) {
	repo := t.TempDir()
	writeFixtureModule(t, repo)
	if err := buildRun(buildOpts{Component: "cli", RepoDir: repo, SrcDir: repo, DispatcherDir: repo,
		Bump: "patch", DryRun: true, NoVulncheck: true, SignKey: testMinisignKey(t)}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(repo, "versions", "cli.stamp")); !os.IsNotExist(err) {
		t.Fatalf("--dry-run wrote versions/cli.stamp (err=%v); a never-published stamp must not be recorded", err)
	}
	out, err := exec.Command("git", "-C", repo, "status", "--porcelain", "versions/cli.stamp").CombinedOutput()
	if err != nil {
		t.Fatalf("git status: %v\n%s", err, out)
	}
	if strings.TrimSpace(string(out)) != "" {
		t.Fatalf("git status --porcelain versions/cli.stamp = %q, want clean", out)
	}
}
