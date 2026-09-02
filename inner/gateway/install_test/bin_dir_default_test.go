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
const wantBinDirDefault = "/usr/local/burrowee/bin"

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
// So this asserts all three separable products of that surface — units
// written, the restart handed to the init system, and the version anchor
// recorded in $BIN_DIR — from an ordinary default install with no PREFIX in
// sight.
//
// The second product, "units handed to the init system", USED to be asserted
// as "load_units restarted the SERVE unit synchronously" — true right up
// until Task 9's own predecessor, when that restart moved off this script's
// foreground into a detached guard (guard_arm, armed before the first write)
// specifically so a severed tunnelled operator does not take the daemon down
// with them. A synchronous stub-calls.log check could not see a restart that
// might not have happened yet by the time runStaged returns, so the
// assertion was dropped rather than left to pass vacuously.
//
// Task 9 restores it, in the shape the new architecture actually offers:
// the guard itself (not the serve unit) is handed to the init system
// (guardArmCall), and the transaction's own phase file reaches "handoff" —
// the token that means "this script has done everything it is going to do
// and the restart is now the guard's". Both are true synchronously, by the
// time runStaged returns, without needing a real guard process to have run
// at all (this suite's systemd-run/launchctl stubs only record the call —
// see installShEnv's REATTACH_CEILING comment). The guard's OWN restart of
// the serve unit is covered by tools/guard-rollback.test.sh and friends.
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
	if calls := readFile(t, filepath.Join(home, "stub-calls.log")); !strings.Contains(calls, guardArmCall()) {
		t.Errorf("the guard was never handed to the init system — a default install no longer restarts synchronously, so the guard is what must run:\n%s", calls)
	}
	if got := latestTxnPhase(t, home); got != "handoff" {
		t.Errorf("transaction phase = %q, want %q — the foreground flow did not hand the restart to the guard", got, "handoff")
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

// wantSystemConfigDirDefault / wantSystemDataDirDefault are the other two
// roots of the machine-owned tree, pinned beside $BIN_DIR because the three
// are siblings under ONE parent (/usr/local/burrowee) and the installer
// derives that parent from them — a root that moved on its own would put the
// exec surface in one tree and the state in another.
const (
	wantSystemRootDefault      = "/usr/local/burrowee"
	wantSystemConfigDirDefault = wantSystemRootDefault + "/etc/gateway"
	wantSystemDataDirDefault   = wantSystemRootDefault + "/var/gateway"
)

// seamDefault extracts the `${SEAM:-<default>}` fallback of the given
// assignment from a script's source, failing when the assignment is not
// there in that shape.
func seamDefault(t *testing.T, src []byte, variable, seam string) string {
	t.Helper()
	re := regexp.MustCompile(`(?m)^\s*` + variable + `="\$\{` + seam + `:-([^}"]+)\}"`)
	m := re.FindSubmatch(src)
	if m == nil {
		t.Fatalf(`no %s="${%s:-...}" assignment found — the seam moved shape and this pin no longer covers it`, variable, seam)
	}
	return string(m[1])
}

// TestInstallShSystemRootsAreSiblingsUnderOneTree pins the config and data
// roots and the fact that all three share the parent $BIN_DIR is derived
// from. Every one of these is a real, fixed system path, asserted as source
// text for the same reason the $BIN_DIR pin above is.
func TestInstallShSystemRootsAreSiblingsUnderOneTree(t *testing.T) {
	src := mustRead(t, installShPath(t))
	if got := seamDefault(t, src, "SYS_CONFIG_DIR", "BURROWEE_SYSTEM_CONFIG_DIR"); got != wantSystemConfigDirDefault {
		t.Errorf("install.sh's SYS_CONFIG_DIR default = %q, want %q", got, wantSystemConfigDirDefault)
	}
	if got := seamDefault(t, src, "SYS_DATA_DIR", "BURROWEE_SYSTEM_DATA_DIR"); got != wantSystemDataDirDefault {
		t.Errorf("install.sh's SYS_DATA_DIR default = %q, want %q", got, wantSystemDataDirDefault)
	}
	if got := filepath.Dir(wantBinDirDefault); got != wantSystemRootDefault {
		t.Errorf("the parent of $BIN_DIR (%s) is %q, want %q — the exec root must be inside the tree it serves", wantBinDirDefault, got, wantSystemRootDefault)
	}
	if !strings.Contains(string(src), `SYSTEM_ROOT="$(dirname "$BIN_DIR")"`) {
		t.Errorf("install.sh no longer derives SYSTEM_ROOT from $BIN_DIR — a sandboxed run could then default the tree to the real %s", wantSystemRootDefault)
	}
}

// TestGuardShDefaultsMatchInstallSh pins guard.sh to the same three roots.
// The guard is execed as root by the supervisor with only a transaction
// directory as argument; it reads $SYS_DATA_DIR for running.json and $BIN_DIR
// for the binary it version-probes, so defaults that lagged install.sh's
// would have it watch a tree the daemon no longer writes and report a
// restart that never happened.
func TestGuardShDefaultsMatchInstallSh(t *testing.T) {
	src := mustRead(t, guardShPath(t))
	for _, pin := range []struct{ variable, seam, want string }{
		{"BIN_DIR", "BURROWEE_BIN_DIR", wantBinDirDefault},
		{"SYS_CONFIG_DIR", "BURROWEE_SYSTEM_CONFIG_DIR", wantSystemConfigDirDefault},
		{"SYS_DATA_DIR", "BURROWEE_SYSTEM_DATA_DIR", wantSystemDataDirDefault},
	} {
		if got := seamDefault(t, src, pin.variable, pin.seam); got != pin.want {
			t.Errorf("guard.sh's %s default = %q, want %q (install.sh's)", pin.variable, got, pin.want)
		}
	}
}
