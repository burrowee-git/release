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
package install_test

import (
	"os"
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

// TestInstallShLoadsTheSweepFromTheBundleAndCallsIt is the seam: the sweep is
// not open-coded in this installer any more, so "it ran" means "the library
// shipped beside me was sourced and its entry point was called".
func TestInstallShLoadsTheSweepFromTheBundleAndCallsIt(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	record := filepath.Join(t.TempDir(), "sweep-env")
	stageSweepLib(t, staging, record, shippedSweepList)

	out, err := runStaged(t, stageInstaller(t, staging), staging, home, stub)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
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

// TestInstallShSweepsAfterTheUnitsAreLoaded pins the ordering as a fact about
// this run rather than a claim about where the call sits in the file.
//
// It works because the staged library appends to the SAME log as the stubbed
// init system; two streams cannot be ordered against each other, and an
// ordering test that compares stdout to a call log is really asserting nothing.
// Forced Linux so the load step is a single unambiguous systemctl line on any
// host the suite runs on.
//
// The ordering is a safety property: a host arriving here may still be running
// a unit whose ExecStart names the per-user path, and on macOS the
// KeepAlive.PathState this installer writes keys off the binary's existence, so
// unlinking it stops the running daemon rather than staling its next restart.
func TestInstallShSweepsAfterTheUnitsAreLoaded(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystemFor(t, "linux")
	staging := t.TempDir()
	seedDummyBins(t, staging)
	stageSweepLib(t, staging, filepath.Join(t.TempDir(), "sweep-env"), shippedSweepList)

	out, err := runStaged(t, stageInstaller(t, staging), staging, home, stub)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	calls := readFile(t, filepath.Join(home, "stub-calls.log"))
	loaded := strings.Index(calls, "systemctl restart burrowee-gateway.service")
	swept := strings.Index(calls, "sweep ran")
	if loaded < 0 {
		t.Fatalf("the units were never loaded; calls:\n%s", calls)
	}
	if swept < 0 {
		t.Fatalf("the sweep was never called; calls:\n%s\noutput:\n%s", calls, out)
	}
	if swept < loaded {
		t.Errorf("the sweep ran BEFORE the units were loaded — a unit still naming the per-user "+
			"path would have been executing that binary; calls:\n%s", calls)
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
	seedDummyBins(t, staging)
	// migrations/ exists (so this is a CURRENT bundle) but the library does not.
	if err := os.MkdirAll(filepath.Join(staging, "migrations"), 0o755); err != nil {
		t.Fatal(err)
	}

	out, err := runStaged(t, stageInstaller(t, staging), staging, home, stub)
	if err != nil {
		t.Fatalf("a missing cleanup library must not fail the install: %v\n%s", err, out)
	}
	assertContains(t, out, "THIS RELEASE IS INCOMPLETE", "lib_stale_user_bins.sh")
	// The binaries this run installed are still there — the refusal is about
	// the sweep, not about the install.
	for _, b := range allBins {
		assertPresent(t, filepath.Join(binDir(home), b), "the install was abandoned over a missing cleanup library")
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
	seedDummyBins(t, staging)
	// A library that has fallen a binary behind this installer.
	stageSweepLib(t, staging, filepath.Join(t.TempDir(), "sweep-env"),
		"burrowee burrowee-gateway burrowee-gateway-cli burrowee-gateway-console burrowee-register")

	out, err := runStaged(t, stageInstaller(t, staging), staging, home, stub)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
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
