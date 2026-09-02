// stale_user_bins_test.go — install.sh's half of the stale per-user binary
// sweep: it LOADS the sweep out of the bundle and RUNS it, after the units
// naming $BIN_DIR are loaded.
//
// WHY THE BEHAVIOURAL TESTS ARE NOT HERE ANY MORE. The sweep itself moved into
// migrations/lib_stale_user_bins.sh in the GATEWAY repo, sourced by this
// installer and by the gateway's 0.2.0 ladder rung out of the same shipped
// directory — one implementation, because every guard in it fails silently in
// the safe-looking direction and a second copy that drifted would look exactly
// like the first right up to the deletion it got wrong. That file is not in
// this repo, so the only fixture this suite could offer it is one this suite
// wrote itself; asserting "the foreign file survived" against a library this
// test authored proves something about the fixture and nothing about the
// shipped sweep. Those claims — operator home vs $HOME, provably-ours,
// exact-names-never-a-glob, the shared dispatcher, idempotence — are tested in
// the gateway repo against the real library
// (internal/updatescript/migration_stale_user_bins_test.go).
//
// WHAT IS LEFT HERE IS THE SEAM, and it is genuinely this repo's: does
// install.sh find the library, load it, call it, at the right moment, with the
// environment it resolved — and does it say so loudly when the bundle it was
// handed cannot answer. A recording stub is the RIGHT fixture for those, because
// the claim is about the call and not about what the callee does.
//
// EVERY PATH HERE IS A FIXTURE TREE under t.TempDir(). Nothing in this file may
// resolve to a real $HOME/.local/bin — the machines this suite runs on have
// live burrowee installs in exactly that directory.
//
// WHERE THE SEAM IS DRIVEN FROM, AND WHY IT MOVED TWICE.
//
// It was reachable from a plain fresh install once: render units, load them,
// THEN sweep. Task 7 took load_units and everything after it off that path, so
// these tests were retargeted onto BURROWEE_UNITS_ONLY, which was then the one
// foreground entry point that still did exactly this — load, then sweep, in one
// synchronous process.
//
// It is not any more. `service install` and `doctor --fix` reach install.sh in
// that mode, both typed in a session routinely tunnelled through the gateway
// they restart, so the restart went to the guard there too — and the sweep went
// with it rather than being left behind: it deletes per-user binaries, and
// until the daemon has actually restarted onto the loaded units a still-running
// per-user process may still name one. On macOS the serve plist's
// KeepAlive.PathState keys off the binary's existence, so unlinking it does not
// stale a future restart, it stops the running daemon.
//
// SO THE PRODUCTION CALL SITE IS NOW guard.sh, and it is one line:
//
//	BURROWEE_SOURCE_ONLY=1 sh -c '. "$0"; sweep_stale_user_bins' \
//	    "$BIN_DIR/install.sh"
//
// (guard.sh's sweep_stale_bins_via_kept_installer — the ROOT-SECURE copy under
// $BIN_DIR, never the operator-writable one under $GW_HOME, and never by
// re-entering `service install`, which would arm a second guard inside the
// first one's success path.)
//
// These tests drive that exact command. It is not a stand-in for the real call
// — it IS the real call, with the same $0 steering that makes install.sh's own
// `$(dirname "$0")/migrations` resolution find the library beside it. What the
// tests own is unchanged: does install.sh find the library, load it, call it,
// with the environment it resolved, and say so loudly when the bundle it was
// handed cannot answer.
//
// THE ORDERING CLAIM DID NOT COME WITH IT, because it cannot: "after a verified
// restart" is now a property of guard.sh's do_restart, and this suite's
// launchctl/systemd-run stubs never spawn a guard. It is covered against the
// real guard.sh in tools/guard-rollback.test.sh, per platform shape, from both
// sides — t_guard_ok_sweeps_stale_bins (it runs on the verified branch) and
// t_guard_does_not_sweep_when_the_restart_fails (it does NOT run on the
// rollback branch). The half that stayed here is the negative that protects the
// move: TestUnitsOnlyDoesNotSweepInItsOwnForeground below.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// shippedSweepList is $STALE_USER_BINS as the gateway's library declares it,
// which install.sh cross-checks against its own $BINS. Written out rather than
// derived from allBins so that a change to one is a change a reader can see
// against the other — which is the whole point of the cross-check.
const shippedSweepList = "burrowee burrowee-gateway burrowee-gateway-cli burrowee-gateway-console burrowee-register burrowee-gateway-updater"

// stageSweepLib writes a RECORDING stand-in for the shipped library at
// <dir>/migrations/lib_stale_user_bins.sh. It records the environment
// install.sh resolved before calling it, appends to the shared stub log so its
// call can be ORDERED against the init-system calls, and declares whatever bin
// list the caller asks for.
//
// It deliberately deletes nothing: the deletion is the gateway library's
// contract and is tested there. Recording it here would only assert that this
// file's own shell works.
func stageSweepLib(t *testing.T, dir, recordPath, binList string) {
	t.Helper()
	mig := filepath.Join(dir, "migrations")
	if err := os.MkdirAll(mig, 0o755); err != nil {
		t.Fatal(err)
	}
	body := "STALE_USER_BINS=" + shQuote(binList) + "\n" +
		"remove_stale_user_bins() {\n" +
		"  { echo \"BIN_DIR=$BIN_DIR\"\n" +
		"    echo \"STALE_USER_BINS=$STALE_USER_BINS\"\n" +
		"    echo \"LAUNCHD_DIR=$LAUNCHD_DIR\"\n" +
		"    echo \"SYSTEMD_DIR=$SYSTEMD_DIR\"\n" +
		"    echo \"HOME=$HOME\"; } > " + shQuote(recordPath) + "\n" +
		"  [ -n \"${STUB_LOG:-}\" ] && echo \"sweep ran\" >> \"$STUB_LOG\"\n" +
		"  echo \"fake sweep: called\"\n" +
		"}\n"
	if err := os.WriteFile(filepath.Join(mig, "lib_stale_user_bins.sh"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}

// runSweepViaGuardSeam invokes sweep_stale_user_bins exactly as guard.sh's
// sweep_stale_bins_via_kept_installer does: BURROWEE_SOURCE_ONLY=1 (so the mode
// dispatch returns before any mode is entered), `sh -c '. "$0"; …'` with the
// installer's path as $0 (sh has no other portable way to steer $0, and
// install.sh's own `$(dirname "$0")/migrations` resolution depends on it), and
// a subshell rather than a dot-source (install.sh defines BIN_DIR and
// SYS_DATA_DIR, which the guard also uses).
//
// script is the staged installer; the library must sit at
// <dir of script>/migrations/lib_stale_user_bins.sh, which is the layout
// ensure_root_exec_surface leaves under $BIN_DIR on a real host.
func runSweepViaGuardSeam(t *testing.T, script, home, stubDir string) (string, error) {
	t.Helper()
	cmd := exec.Command("sh", "-c", `. "$0"; sweep_stale_user_bins`, script)
	cmd.Dir = home
	cmd.Env = append(installShEnv(home, stubDir), "BURROWEE_SOURCE_ONLY=1")
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// TestInstallShLoadsTheSweepFromTheBundleAndCallsIt is the seam: the sweep is
// not open-coded in this installer any more, so "it ran" means "the library
// shipped beside me was sourced and its entry point was called".
func TestInstallShLoadsTheSweepFromTheBundleAndCallsIt(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedMigrateCapableCLI(t, home)
	record := filepath.Join(t.TempDir(), "sweep-env")
	stageSweepLib(t, staging, record, shippedSweepList)

	out, err := runSweepViaGuardSeam(t, stageInstaller(t, staging), home, stub)
	if err != nil {
		t.Fatalf("the sweep seam guard.sh uses failed: %v\n%s", err, out)
	}
	assertContains(t, out, "fake sweep: called")

	// THE ENVIRONMENT IT WAS CALLED WITH, not merely that it was called. The
	// library's guards read every one of these: $BIN_DIR is what stops it
	// deleting the install this run just made, and the two unit directories are
	// where it looks for a unit still naming the per-user path.
	got := readFile(t, record)
	for _, want := range []string{
		"BIN_DIR=" + binDir(home),
		"STALE_USER_BINS=" + shippedSweepList,
		"LAUNCHD_DIR=" + launchdDir(home),
		"SYSTEMD_DIR=" + systemdDir(home),
	} {
		if !strings.Contains(got, want+"\n") {
			t.Errorf("the sweep was called without %q; it saw:\n%s", want, got)
		}
	}
}

// TestUnitsOnlyDoesNotSweepInItsOwnForeground is the surviving half of
// TestInstallShSweepsAfterTheUnitsAreLoaded, and it is a negative because the
// positive it replaced can no longer be observed from here.
//
// That test pinned an ORDERING — the sweep must run after the units are loaded
// — by having the staged library append to the SAME log as the stubbed init
// system, so the two could be compared in one stream. It was a safety property,
// not tidiness: a host arriving at an install may still be running a unit whose
// ExecStart names the per-user path, and on macOS the KeepAlive.PathState this
// installer writes keys off the binary's existence, so unlinking it stops the
// running daemon rather than staling its next restart.
//
// The two events are no longer in one process. The load is the guard's restart,
// and the sweep is the guard's post-success work — both on the far side of a
// handoff, in a child of launchd/systemd this suite's stubs deliberately never
// spawn. Ordering them from here would mean asserting against a process that
// does not run. tools/guard-rollback.test.sh owns that claim now, from both
// sides, against the real guard.sh: t_guard_ok_sweeps_stale_bins (the sweep
// runs on the verified-serving branch) and t_guard_does_not_sweep_when_the_-
// restart_fails (it does not run on the rollback branch — which is the same
// safety property stated as the failure it prevents).
//
// What is checkable here, and what protects that arrangement, is the negative:
// install.sh's own foreground must not call the sweep on this path. A
// regression that put it back — the natural "shouldn't the installer clean up
// after itself?" edit — would delete per-user binaries while the daemon is
// still the OLD process running from one of them, and it would do it before the
// guard has restarted anything at all.
func TestUnitsOnlyDoesNotSweepInItsOwnForeground(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystemFor(t, "linux")
	staging := t.TempDir()
	seedMigrateCapableCLI(t, home)
	record := filepath.Join(t.TempDir(), "sweep-env")
	stageSweepLib(t, staging, record, shippedSweepList)

	out, err := runStaged(t, stageInstaller(t, staging), home, home, stub, "BURROWEE_UNITS_ONLY=1")
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	// Not vacuous: the library really is where install.sh would find it, so an
	// absent call is a decision and not a missing fixture. The seam test above
	// runs the identical staging through guard.sh's own invocation and gets
	// "fake sweep: called" out of it.
	if _, statErr := os.Stat(filepath.Join(staging, "migrations", "lib_stale_user_bins.sh")); statErr != nil {
		t.Fatalf("fixture broken: no sweep library beside the staged installer: %v", statErr)
	}
	if strings.Contains(out, "fake sweep: called") {
		t.Errorf("units-only ran the stale-binary sweep in its own foreground — the daemon has not restarted onto the new units yet, so a still-running per-user process may still name a binary this deletes, and on Darwin deleting it STOPS that daemon:\n%s", out)
	}
	if _, statErr := os.Stat(record); statErr == nil {
		t.Errorf("the sweep recorded a call at %s — it must not run until the guard has verified the restart", record)
	}
}

// TestInstallShIsLoudWhenTheBundleCarriesNoSweepLibrary. A migrations/ dir with
// no library in it is a MIS-ASSEMBLED release — this project has shipped one
// (gateway v0.2.0.2026.08.07 went out with no migrations/ at all, signed and
// notarized, because `zip -j` silently dropped the directory). The install must
// still succeed, because the sweep is a cleanup and not a precondition, and it
// must say what it did not do.
func TestInstallShIsLoudWhenTheBundleCarriesNoSweepLibrary(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedMigrateCapableCLI(t, home)
	// migrations/ exists (so this is a CURRENT bundle) but the library does not.
	if err := os.MkdirAll(filepath.Join(staging, "migrations"), 0o755); err != nil {
		t.Fatal(err)
	}

	out, err := runSweepViaGuardSeam(t, stageInstaller(t, staging), home, stub)
	if err != nil {
		t.Fatalf("a missing cleanup library must not fail the sweep step: %v\n%s", err, out)
	}
	assertContains(t, out, "THIS RELEASE IS INCOMPLETE", "lib_stale_user_bins.sh")
	// The claim is the same as ever — a missing cleanup library must not cost
	// the binaries already on disk — checked against the ones
	// seedMigrateCapableCLI put there, which is also what a real host has when
	// the guard reaches this step: everything already placed, nothing left to
	// place.
	for _, b := range allBins {
		assertPresent(t, filepath.Join(binDir(home), b), "a missing cleanup library must not disturb the binaries already on disk")
	}
}

// TestInstallShIsSilentWhenTheBundleHasNoMigrationsAtAll — the OTHER shape, and
// it must not be confused with the one above. A bundle with no migrations/ dir
// is an OLD bundle (a $GW_HOME self-copy kept by an install that predates the
// directory), not a broken one, and warning about it would put a permanent
// complaint on a host where nothing is wrong.
func TestInstallShIsSilentWhenTheBundleHasNoMigrationsAtAll(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)

	out, err := runStaged(t, stageInstaller(t, staging), staging, home, stub)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	for _, noise := range []string{"THIS RELEASE IS INCOMPLETE", "lib_stale_user_bins.sh"} {
		if strings.Contains(out, noise) {
			t.Errorf("a pre-migrations bundle was warned about %q:\n%s", noise, out)
		}
	}
}

// TestInstallShReportsASweepListThatDisagreesWithWhatItInstalls. $BINS is what
// this installer PLACES; the library's $STALE_USER_BINS is what the sweep
// REMOVES, and the two live in different repositories. A name added to one and
// not the other is either a binary that is installed and never swept — a copy
// left shadowing $BIN_DIR on PATH, which is this whole defect — or one swept and
// never installed. Neither is visible otherwise: the sweep's normal output on a
// converged host is nothing at all.
func TestInstallShReportsASweepListThatDisagreesWithWhatItInstalls(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedMigrateCapableCLI(t, home)
	// A library that has fallen a binary behind this installer.
	stageSweepLib(t, staging, filepath.Join(t.TempDir(), "sweep-env"),
		"burrowee burrowee-gateway burrowee-gateway-cli burrowee-gateway-console burrowee-register")

	out, err := runSweepViaGuardSeam(t, stageInstaller(t, staging), home, stub)
	if err != nil {
		t.Fatalf("the sweep seam guard.sh uses failed: %v\n%s", err, out)
	}
	assertContains(t, out, "the two lists disagree", "burrowee-gateway-updater")
	// It still runs the sweep: a disagreement is a warning about coverage, not
	// a reason to stop removing the names both lists DO agree on.
	assertContains(t, out, "fake sweep: called")
}

// assertPresent names the file in the failure so a red run says which guard let
// go or held on.
func assertPresent(t *testing.T, path, why string) {
	t.Helper()
	if _, err := os.Stat(path); err != nil {
		t.Errorf("%s is gone — %s", path, why)
	}
}
