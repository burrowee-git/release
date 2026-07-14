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
	wantEntries := []string{"burrowee", "burrowee-cli", "burrowee-cli-updater", "install.sh"}
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
