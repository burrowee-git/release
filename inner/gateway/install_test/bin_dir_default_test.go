// bin_dir_default_test.go — the ONE $BIN_DIR (/usr/local/bin), pinned
// statically, and the refusal that keeps it the only one.
//
// The literal destination is deliberately a SOURCE-TEXT assertion, never a
// dynamic run: it is a real, fixed system path, and exercising it for real on
// the host running this suite is exactly what the suite's hard rule (never
// touch real /usr/local) forbids. Every dynamic test in this package sets
// BURROWEE_BIN_DIR (installShEnv's default) to redirect it somewhere
// disposable; this file is the one place the literal itself is checked, and it
// does so by reading install.sh's own source rather than running it.
//
// The REFUSAL below is the opposite: it must be run, because "PREFIX is
// rejected" is a claim about behaviour at a moment (before anything is placed),
// not about a string in a file.
package install_test

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// wantBinDirDefault is the FULL $BIN_DIR this repo's install.sh resolves to.
// The gateway repo's sibling pin
// (internal/updatescript/update_sh_default_test.go) checks a related but
// textually different thing — update.sh's PREFIX fallback ("/usr/local", one
// path component short) — because update.sh still computes BIN_DIR as
// "$PREFIX/bin" in two steps where install.sh's BURROWEE_BIN_DIR seam
// collapses that into one. Both describe the same real destination
// (/usr/local/bin); changing either is still a deliberate, cross-repo
// decision — update both pins in the same change, or an update and a fresh
// install can silently resolve to two different directories.
const wantBinDirDefault = "/usr/local/bin"

// binDirDefaultRe matches install.sh's BIN_DIR assignment and captures the
// ${BURROWEE_BIN_DIR:-<default>} fallback — the real destination a production
// host resolves; BURROWEE_BIN_DIR itself is a test-only redirect, never set on
// a real host.
var binDirDefaultRe = regexp.MustCompile(`(?m)^\s*BIN_DIR="\$\{BURROWEE_BIN_DIR:-([^}"]+)\}"`)

// TestInstallShBinDirDefaultMatchesTheExpectedRoot pins install.sh's own
// destination. It must FAIL if it moves without this test being updated
// deliberately — that is the whole point: a silent drift here is a host
// getting binaries in a different directory than every doc, comment and the
// Go side's RootExecDir() describe.
func TestInstallShBinDirDefaultMatchesTheExpectedRoot(t *testing.T) {
	data, err := os.ReadFile(installShPath(t))
	if err != nil {
		t.Fatalf("read install.sh: %v", err)
	}
	m := binDirDefaultRe.FindSubmatch(data)
	if m == nil {
		t.Fatalf(`install.sh: no BIN_DIR="${BURROWEE_BIN_DIR:-.../bin}" assignment found — ` +
			"the destination moved shape and this test can no longer pin it")
	}
	if got := string(m[1]); got != wantBinDirDefault {
		t.Errorf("install.sh's BIN_DIR = %q, want %q — "+
			"update the gateway repo's update.sh/migrations/*.sh defaults in the same change if this is deliberate",
			got, wantBinDirDefault)
	}
}

// TestInstallShHasNoPerUserPrefixBranch is the static half of the collapse: the
// per-user flow must be GONE from the source, not merely unreachable.
//
// Two things are banned and they fail differently. `BIN_DIR="$PREFIX/bin"` is
// the branch itself coming back. `BIN_DIR_IS_DEFAULT` is subtler and is the one
// that actually caused the outage this change exists for: while that variable
// existed it gated ensure_root_exec_surface, render_units, load_units,
// migrate_from_legacy and record_installed_version, so a single reintroduced
// assignment switches off the entire privileged surface again — with every
// binary still landing correctly, which is what made it invisible.
func TestInstallShHasNoPerUserPrefixBranch(t *testing.T) {
	src := string(mustRead(t, installShPath(t)))
	for _, banned := range []string{`BIN_DIR="$PREFIX/bin"`, "BIN_DIR_IS_DEFAULT"} {
		if strings.Contains(src, banned) {
			t.Errorf("install.sh still carries %q — the per-user prefix flow is supposed to be gone, "+
				"not disabled; see this file's header for why a gate is worse than a branch", banned)
		}
	}
}

// TestInstallShRefusesAMisdirectingPrefix — decision 3 of the plan, executed.
//
// Silently overriding a PREFIX that names somewhere else would be the same
// class of surprise as the bug being fixed, pointed the other way: the operator
// asks for one directory and a different one is written, root-owned, without a
// word. So the run must FAIL, name what changed (0.2.0) and where things go now
// (/usr/local/bin) — and it must do so BEFORE placing anything, which is
// asserted separately because a refusal after a half-install is not a refusal.
//
// The $HOME/.local it uses is genuinely divergent, so this stays exactly as
// true under the divergent-only rule; prefix_gate_test.go owns the other half
// (a PREFIX that resolves to $BIN_DIR is honoured).
func TestInstallShRefusesAMisdirectingPrefix(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)

	out, err := runStaged(t, installShPath(t), staging, home, stub, "PREFIX="+home+"/.local")
	if err == nil {
		t.Fatalf("install.sh honoured PREFIX instead of refusing it:\n%s", out)
	}
	assertContains(t, out, "PREFIX", "0.2.0", wantBinDirDefault)

	// Nothing placed, in either candidate directory: not the prefix the
	// operator asked for, and not the default they did not ask for.
	for _, dir := range []string{devBinDir(home), binDir(home)} {
		for _, b := range allBins {
			if _, statErr := os.Stat(filepath.Join(dir, b)); statErr == nil {
				t.Errorf("%s was placed in %s despite the refusal — the check ran too late to matter", b, dir)
			}
		}
	}
}

// TestDefaultInstallEngagesThePrivilegedSurface is the regression the outage
// actually needs, and no other test in this package states it as one claim.
//
// The old shape did not fail — it succeeded, quietly, doing a third of the job:
// with PREFIX set (which the outer bootstrap ALWAYS set), every binary was
// placed and then render_units, load_units, migrate_from_legacy and
// record_installed_version each returned early. The install printed no error,
// exited 0, and left a host with binaries in a directory its root consumers
// cannot see and no service units at all.
//
// So this asserts the three separable products of that surface together —
// units written, units handed to the init system, version anchor recorded in
// $BIN_DIR — from an ordinary default install with no PREFIX in sight.
func TestDefaultInstallEngagesThePrivilegedSurface(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	// record_installed_version writes the $BIN_DIR copy only on a host that
	// has been converged to the root scheme; the system config root is what
	// says so, and nothing else in this run creates it.
	if err := os.MkdirAll(sysConfigDir(home), 0o755); err != nil {
		t.Fatal(err)
	}

	out, err := runStaged(t, installShPath(t), staging, home, stub,
		"BURROWEE_VERSION=gateway/v0.2.0.2026.08.13.4f1c3ec8")
	if err != nil {
		t.Fatalf("default install failed: %v\n%s", err, out)
	}

	if _, statErr := os.Stat(coreUnitPath(home)); statErr != nil {
		t.Errorf("no service unit at %s — render_units did not run on a default install: %v", coreUnitPath(home), statErr)
	}
	if calls := readFile(t, filepath.Join(home, "stub-calls.log")); !strings.Contains(calls, serviceStartCall()) {
		t.Errorf("the init system was never asked to run the unit — load_units did not run:\n%s", calls)
	}
	anchor := filepath.Join(binDir(home), ".installed-version")
	if got, statErr := os.ReadFile(anchor); statErr != nil {
		t.Errorf("no version anchor at %s — record_installed_version did not run: %v", anchor, statErr)
	} else if strings.TrimSpace(string(got)) != "v0.2.0.2026.08.13.4f1c3ec8" {
		t.Errorf("version anchor = %q, want v0.2.0.2026.08.13.4f1c3ec8", strings.TrimSpace(string(got)))
	}
}

// TestBurroweeBinDirStillRedirectsTheDestination keeps the surviving test seam
// honest. It is the only reason this suite can exercise the default at all
// (decision 4), so it has to be shown redirecting — and shown NOT to change
// what the install means: the privileged surface engages exactly the same,
// which is what makes the rest of this package's fixtures representative.
func TestBurroweeBinDirStillRedirectsTheDestination(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	elsewhere := filepath.Join(t.TempDir(), "redirected", "bin")

	out, err := runStaged(t, installShPath(t), staging, home, stub, "BURROWEE_BIN_DIR="+elsewhere)
	if err != nil {
		t.Fatalf("install.sh failed with a redirected $BIN_DIR: %v\n%s", err, out)
	}
	for _, b := range allBins {
		if _, statErr := os.Stat(filepath.Join(elsewhere, b)); statErr != nil {
			t.Errorf("%s did not follow BURROWEE_BIN_DIR to %s: %v", b, elsewhere, statErr)
		}
		if _, statErr := os.Stat(filepath.Join(binDir(home), b)); statErr == nil {
			t.Errorf("%s was placed in %s too — the redirect is not a redirect", b, binDir(home))
		}
	}
	if !strings.Contains(readFile(t, coreUnitPath(home)), elsewhere) {
		t.Errorf("the unit does not name the redirected $BIN_DIR %s:\n%s", elsewhere, readFile(t, coreUnitPath(home)))
	}
}

// mustRead reads a file or fails the test.
func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return b
}
