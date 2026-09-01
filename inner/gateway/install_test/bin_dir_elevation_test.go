// bin_dir_elevation_test.go — the DEFAULT $BIN_DIR's own elevation path:
// place_all_bins / decide_bin_place_elevated, driven against a $BIN_DIR this
// unprivileged test process genuinely cannot write (chmod 0500) — the
// nearest a suite that must never touch the real /usr/local can get to the
// production shape (a root-owned default), via install.sh's actual
// elevation mechanism rather than a seam that only asserts the outcome.
package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// requireUnprivilegedForElevation skips a test whose whole subject is a
// refusal root cannot be given.
func requireUnprivilegedForElevation(t *testing.T) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("running as root: no chmod can refuse this process, so a root-owned $BIN_DIR cannot be staged here")
	}
}

// stageUnwritableBinDir returns a BURROWEE_BIN_DIR value this test process
// cannot write — the nearest an unprivileged test can get to the real
// root-owned /usr/local/bin an operator actually hits.
func stageUnwritableBinDir(t *testing.T) string {
	t.Helper()
	requireUnprivilegedForElevation(t)
	dir := filepath.Join(t.TempDir(), "usr-local-bin")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })
	probe := filepath.Join(dir, "probe")
	if err := os.WriteFile(probe, []byte("x"), 0o600); err == nil {
		_ = os.Remove(probe)
		t.Skipf("this filesystem ignores 0500 on %s — a root-owned bin dir cannot be simulated here", dir)
	}
	return dir
}

// installFakeRootSudo overwrites stubDir's `sudo` (install.sh calls the bare
// name, resolved via $PATH — it has no $SUDO env override the way the
// gateway repo's update.sh does) with a stand-in that RUNS the command it is
// given with binDir temporarily writable, so the elevated path really
// succeeds where the unelevated one really fails. Records every argv,
// including any leading -n, to logPath.
//
// Never a real sudo: this suite must not be able to touch the host it runs
// on. It leaves binDir and any staging directory it created MODE 0500 on
// completion — on a real host the staging directory is created BY ROOT
// inside a root-owned $BIN_DIR, so an unelevated `install` into it is
// refused just like the final placement is. Without this the stub — running
// as the same unprivileged user — would leave a writable staging dir behind,
// and a placement that had stopped elevating its per-binary installs would
// still pass.
func installFakeRootSudo(t *testing.T, stubDir, logPath, binDir string) {
	t.Helper()
	stageGlob := shQuote(binDir) + "/.burrowee-install.*"
	script := "#!/bin/sh\n" +
		"echo \"$@\" >> " + shQuote(logPath) + "\n" +
		"while [ $# -gt 0 ]; do case \"$1\" in -n) shift ;; *) break ;; esac; done\n" +
		"_grant() { chmod \"$1\" " + shQuote(binDir) + "; for _d in " + stageGlob + "; do [ -d \"$_d\" ] && chmod \"$2\" \"$_d\"; done; return 0; }\n" +
		"_grant u+rwx u+rwx\n" +
		"\"$@\"\n" +
		"_rc=$?\n" +
		"_grant 0500 0500\n" +
		"exit $_rc\n"
	if err := os.WriteFile(filepath.Join(stubDir, "sudo"), []byte(script), 0o755); err != nil {
		t.Fatalf("write fake sudo: %v", err)
	}
}

// installFailingSudoFor overwrites stubDir's `sudo` with one that refuses
// only a call whose argv names refuseIfContains, passing every other call
// straight through (no tty, no cached credentials, but only FOR that one
// destination).
//
// Not a blanket refusal: the install transaction (txn_begin) and the guard
// (guard_arm) need real elevation for their own destinations — sandboxed
// paths under $SYS_DATA_DIR and the libexec seam, both unrelated to $BIN_DIR
// — before place_all_bins ever runs. A sudo that refused everything would
// fail the run at the transaction, before place_all_bins is reached at all,
// pinning nothing about $BIN_DIR's own elevation decision — which is the
// entire subject of the two tests below.
func installFailingSudoFor(t *testing.T, stubDir, refuseIfContains string) {
	t.Helper()
	script := "#!/bin/sh\n" +
		"case \"$*\" in *" + refuseIfContains + "*) exit 1 ;; esac\n" +
		"[ \"$1\" = \"-n\" ] && shift\n" +
		"exec \"$@\"\n"
	if err := os.WriteFile(filepath.Join(stubDir, "sudo"), []byte(script), 0o755); err != nil {
		t.Fatalf("write failing sudo: %v", err)
	}
}

// assertBinDirEmpty fails the test if binDir contains anything at all.
func assertBinDirEmpty(t *testing.T, binDir string) {
	t.Helper()
	entries, err := os.ReadDir(binDir)
	if err != nil {
		t.Fatalf("read %s: %v", binDir, err)
	}
	if len(entries) != 0 {
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("%s is not empty: %v", binDir, names)
	}
}

// TestInstallShElevatesPlacementIntoARootOwnedBinDir is the reported class of
// host: the DEFAULT $BIN_DIR, root-owned, install run by an ordinary user.
// Every binary in BINS must land, and the elevation must have genuinely been
// exercised (proven by the recorder log), not merely assumed.
func TestInstallShElevatesPlacementIntoARootOwnedBinDir(t *testing.T) {
	binDir := stageUnwritableBinDir(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	home := t.TempDir()
	stub := stubInitSystem(t)
	logPath := filepath.Join(t.TempDir(), "sudo.log")
	installFakeRootSudo(t, stub, logPath, binDir)

	out, err := runStaged(t, installShPath(t), staging, home, stub, "BURROWEE_BIN_DIR="+binDir)
	if err != nil {
		t.Fatalf("install.sh failed against a root-owned %s: %v\n%s", binDir, err, out)
	}

	for _, b := range allBins {
		if _, statErr := os.Stat(filepath.Join(binDir, b)); statErr != nil {
			t.Errorf("%s missing from %s: %v", b, binDir, statErr)
		}
	}
	if _, statErr := os.Stat(logPath); statErr != nil {
		t.Errorf("no elevation was attempted, yet %s is unwritable by this user — the placement cannot have been honest", binDir)
	}
	entries, readErr := os.ReadDir(binDir)
	if readErr != nil {
		t.Fatalf("read %s: %v", binDir, readErr)
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".burrowee-install.") {
			t.Errorf("staging directory %s survived the run", e.Name())
		}
	}
}

// TestInstallShDoesNotElevateAWritableBinDir: decide_bin_place_elevated must
// ask whether THIS process can write $BIN_DIR, discovered by a real create, and
// not assume elevation just because the destination is the system one. A host
// whose /usr/local this user owns (a Homebrew Intel Mac, a container running as
// its own user) is the ordinary case for that.
//
// The `sudo` on PATH here always refuses, which is what makes the assertion
// able to fail: had placement elevated blindly, place_all_bins would have died
// on its very first write — the staging mkdir — with "cannot write $BIN_DIR —
// no binary was placed", and none of the six would exist.
//
// The run as a whole still fails, and that is correct rather than incidental:
// past placement comes the privileged surface (ensure_root_exec_surface), which
// genuinely cannot be established without root and refuses rather than writing
// a unit it cannot back. Since the prefix collapse there is no install shape
// that skips it, so "placed but not unit-installed" is the honest outcome for a
// host with no elevation at all.
func TestInstallShDoesNotElevateAWritableBinDir(t *testing.T) {
	requireUnprivilegedForElevation(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	home := t.TempDir()
	stub := stubInitSystem(t)
	installFailingSudoFor(t, stub, binDir(home))

	out, err := runStaged(t, installShPath(t), staging, home, stub)
	if err == nil {
		t.Fatalf("install.sh succeeded with no elevation available; the unit surface cannot have been reached:\n%s", out)
	}
	for _, b := range allBins {
		if _, statErr := os.Stat(filepath.Join(binDir(home), b)); statErr != nil {
			t.Errorf("%s missing from a WRITABLE $BIN_DIR: %v — placement elevated when it did not need to\n%s", b, statErr, out)
		}
	}
}

// TestInstallShPlacesNothingWhenBinDirCannotBeWrittenAtAll is the brief's
// front-door case: elevation itself unavailable, so the FIRST write of
// place_all_bins (creating the staging directory) fails, and $BIN_DIR is
// left exactly as it was found — empty.
func TestInstallShPlacesNothingWhenBinDirCannotBeWrittenAtAll(t *testing.T) {
	binDir := stageUnwritableBinDir(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	home := t.TempDir()
	stub := stubInitSystem(t)
	installFailingSudoFor(t, stub, binDir)

	out, err := runStaged(t, installShPath(t), staging, home, stub, "BURROWEE_BIN_DIR="+binDir)
	if err == nil {
		t.Fatalf("install.sh succeeded against a root-owned $BIN_DIR with no elevation available:\n%s", out)
	}
	if !strings.Contains(out, "no binary was placed") {
		t.Errorf("the refusal does not say nothing was placed:\n%s", out)
	}
	assertBinDirEmpty(t, binDir)
}

// TestInstallShPlacesNothingWhenOneBinaryCannotBeStaged is the set property:
// elevation WORKS (the staging directory gets created), but one binary's
// source cannot be staged partway through. The host must be left exactly as
// it was — none of BINS present — never a mix of some new, some absent,
// which is what the restart at the end of a real run would come back on.
func TestInstallShPlacesNothingWhenOneBinaryCannotBeStaged(t *testing.T) {
	binDir := stageUnwritableBinDir(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	// The fourth name in BINS, so three stage cleanly before the refusal — a
	// failure on the first would pass even without the all-or-nothing commit.
	broken := filepath.Join(staging, "burrowee-gateway-console")
	if err := os.Chmod(broken, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(broken, 0o755) })
	if f, err := os.Open(broken); err == nil {
		_ = f.Close()
		t.Skip("this filesystem ignores 0000 — an unplaceable source cannot be staged here")
	}

	home := t.TempDir()
	stub := stubInitSystem(t)
	logPath := filepath.Join(t.TempDir(), "sudo.log")
	installFakeRootSudo(t, stub, logPath, binDir)

	out, err := runStaged(t, installShPath(t), staging, home, stub, "BURROWEE_BIN_DIR="+binDir)
	if err == nil {
		t.Fatalf("install.sh reported success with a binary it could not stage:\n%s", out)
	}
	assertBinDirEmpty(t, binDir)
}
