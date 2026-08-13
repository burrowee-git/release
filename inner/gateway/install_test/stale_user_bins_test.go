// stale_user_bins_test.go — the sweep of the pre-0.2.0 per-user binaries
// (install.sh: remove_stale_user_bins), which is the other half of
// remove_legacy_user_units: that one removed the units the per-user model left
// running, this one removes what it left on disk.
//
// WHY IT NEEDS ITS OWN FILE OF TESTS. Deleting files out of a user's home is
// the most destructive thing this installer does, and every guard around it
// fails silently in the safe-looking direction: a sweep pointed at the wrong
// home finds nothing and reports success; a "provably ours" check that admits
// too much deletes an operator's own file and reports success too. So each
// guard is exercised as its own claim, with a fixture that would make the
// unguarded version pass.
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

// staleBinFixture stands in for a real burrowee binary: NUL bytes and an ELF
// header around the module path the Go toolchain stamps into every
// github.com/burrowee-git/* executable's build-info blob.
//
// The NULs are load-bearing, not decoration. install.sh decides ownership with
// `grep -qF` over the file, and the whole approach rests on that working
// against BINARY content — a fixture made of plain text would prove the
// predicate matches a string, which was never in doubt, and say nothing about
// the files it will actually be asked about.
func staleBinFixture(name string) []byte {
	return []byte("\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00" +
		"go1.26.5\x00path\tgithub.com/burrowee-git/gateway/cmd/" + name + "\x00\x00\n")
}

// foreignFile is a file that is NOT ours: an operator's own script, of the kind
// that shares a name or a prefix with what this component installs.
const foreignFile = "#!/bin/sh\n# my own wrapper — nothing to do with the vendor\nexec /opt/local/thing \"$@\"\n"

// seedStale writes name→content into the stale per-user bin dir, creating it.
func seedStale(t *testing.T, dir string, files map[string][]byte) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir stale dir: %v", err)
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), body, 0o755); err != nil {
			t.Fatalf("seed stale %s: %v", name, err)
		}
	}
}

// staleOursSet is every name in $BINS, each as a convincing burrowee binary —
// the state a host carries after a pre-0.2.0 install.
func staleOursSet() map[string][]byte {
	files := map[string][]byte{}
	for _, b := range allBins {
		files[b] = staleBinFixture(b)
	}
	return files
}

// assertGone / assertPresent name the file in the failure so a red run says
// which guard let go or held on.
func assertGone(t *testing.T, path, why string) {
	t.Helper()
	if _, err := os.Stat(path); err == nil {
		t.Errorf("%s still exists — %s", path, why)
	}
}

func assertPresent(t *testing.T, path, why string) {
	t.Helper()
	if _, err := os.Stat(path); err != nil {
		t.Errorf("%s is gone — %s", path, why)
	}
}

// TestFreshInstallSweepsTheStalePerUserBinaries is the headline claim: after a
// default install, the copies that shadow $BIN_DIR on PATH are gone, each
// removal is reported, and the binaries this run actually installed are not.
func TestFreshInstallSweepsTheStalePerUserBinaries(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	stale := devBinDir(home)
	seedStale(t, stale, staleOursSet())

	out, err := runStaged(t, installShPath(t), staging, home, stub)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	for _, b := range allBins {
		assertGone(t, filepath.Join(stale, b), "the stale per-user copy still shadows $BIN_DIR on PATH")
		assertPresent(t, filepath.Join(binDir(home), b), "the sweep took the binary this run installed")
		assertContains(t, out, "removed stale per-user binary: "+filepath.Join(stale, b))
	}
}

// TestStaleSweepUsesTheOperatorHomeNotDollarHome — the trap this codebase has
// already paid for once. The documented flow is `curl … | sudo sh`, where $HOME
// is root's, so a sweep written against $HOME looks in a tree no per-user
// install ever wrote to: it finds nothing, prints nothing, exits 0, and every
// shadowing copy survives.
//
// The fixture makes the two answers point at DIFFERENT trees and asserts both
// halves — the operator's copies are gone, and a decoy under $HOME's own
// .local/bin is untouched. A $HOME-based implementation fails both ways round,
// which is what stops this passing for the wrong reason.
func TestStaleSweepUsesTheOperatorHomeNotDollarHome(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)

	// An account resolvable ONLY through the LEGACY_HOME_PARENTS fallback, so
	// this test can never reach a real account's home: getent/dscl know nothing
	// about it, and the parents seam points at a fixture tree.
	parents := t.TempDir()
	operator := "burrowee-fixture-operator"
	operatorStale := filepath.Join(parents, operator, ".local", "bin")
	seedStale(t, operatorStale, staleOursSet())

	// $HOME's own per-user tree, which must be left alone: under sudo this is
	// root's, and root never had a per-user install.
	homeStale := devBinDir(home)
	seedStale(t, homeStale, map[string][]byte{"burrowee-gateway": staleBinFixture("burrowee-gateway")})

	out, err := runStaged(t, installShPath(t), staging, home, stub,
		"SUDO_USER="+operator,
		"BURROWEE_LEGACY_HOME_PARENTS="+parents)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	for _, b := range allBins {
		assertGone(t, filepath.Join(operatorStale, b),
			"the sweep did not resolve $SUDO_USER's home — under sudo $HOME is root's, so this is the tree that matters")
	}
	assertPresent(t, filepath.Join(homeStale, "burrowee-gateway"),
		"the sweep swept $HOME instead of the operator's home")
	assertContains(t, out, "removed stale per-user binary: "+filepath.Join(operatorStale, "burrowee-gateway"))
}

// TestStaleSweepSkipsWhenAUnitStillNamesThePerUserDir — the ordering guard,
// stated as a refusal. A host can carry ANOTHER component's unit still pointing
// into the per-user tree (this installer only rewrites its own), and on macOS
// KeepAlive.PathState means unlinking that binary stops the running daemon
// rather than merely staling its next restart.
func TestStaleSweepSkipsWhenAUnitStillNamesThePerUserDir(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	stale := devBinDir(home)
	seedStale(t, stale, staleOursSet())

	// A co-installed relay's system unit, which nothing in this install rewrites.
	if err := os.MkdirAll(systemdDir(home), 0o755); err != nil {
		t.Fatal(err)
	}
	foreignUnit := filepath.Join(systemdDir(home), "burrowee-relay.service")
	if err := os.WriteFile(foreignUnit,
		[]byte("[Service]\nExecStart="+stale+"/burrowee-relay run\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	out, err := runStaged(t, installShPath(t), staging, home, stub)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	for _, b := range allBins {
		assertPresent(t, filepath.Join(stale, b),
			"a unit still names that directory, so removing from it can stop a running daemon")
	}
	assertContains(t, out, foreignUnit, "still names "+stale)
	if strings.Contains(out, "removed stale per-user binary") {
		t.Errorf("something was removed despite a live reference:\n%s", out)
	}
}

// TestStaleSweepLeavesWhatIsNotOurs — the bar for deleting from a user's home
// is "provably ours", not "named like ours". Two shapes are checked because
// they fail differently: an operator's own file that TAKES one of our exact
// names (a wrapper on PATH), and one that merely shares the prefix — the file a
// `rm ~/.local/bin/burrowee*` would have taken.
func TestStaleSweepLeavesWhatIsNotOurs(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	stale := devBinDir(home)
	seedStale(t, stale, map[string][]byte{
		"burrowee-gateway":     staleBinFixture("burrowee-gateway"),
		"burrowee-gateway-cli": []byte(foreignFile),
		"burrowee-notes":       []byte(foreignFile),
	})

	out, err := runStaged(t, installShPath(t), staging, home, stub)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	assertGone(t, filepath.Join(stale, "burrowee-gateway"), "it carries our build stamp and is ours to remove")
	assertPresent(t, filepath.Join(stale, "burrowee-gateway-cli"),
		"it carries no burrowee build stamp — a same-named file that is not ours must survive")
	assertPresent(t, filepath.Join(stale, "burrowee-notes"),
		"it is not in $BINS at all — the sweep must never glob")
	assertContains(t, out, filepath.Join(stale, "burrowee-gateway-cli")+" carries no burrowee build stamp")
}

// TestStaleSweepKeepsTheDispatcherWhileAnotherComponentIsInstalledThere — the
// bare `burrowee` dispatcher is shared, and the cli component STILL installs
// per-user by design. Removing it because the gateway moved would uninstall
// half of a perfectly good cli.
func TestStaleSweepKeepsTheDispatcherWhileAnotherComponentIsInstalledThere(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	stale := devBinDir(home)
	files := staleOursSet()
	files["burrowee-cli"] = staleBinFixture("burrowee-cli")
	seedStale(t, stale, files)

	out, err := runStaged(t, installShPath(t), staging, home, stub)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	assertPresent(t, filepath.Join(stale, "burrowee"),
		"the cli is still installed there and the dispatcher is shared")
	assertPresent(t, filepath.Join(stale, "burrowee-cli"), "it belongs to another component")
	assertGone(t, filepath.Join(stale, "burrowee-gateway"), "the gateway's own binaries still move")
	assertContains(t, out, "kept "+filepath.Join(stale, "burrowee")+" (dispatcher)")
}

// TestStaleSweepRunsAfterTheUnitsAreLoaded pins the ordering as a fact about
// this run rather than a claim about where the call sits in the file.
//
// It works by putting `rm` on the stubbed PATH so the removals land in the SAME
// log as the init-system calls; two streams cannot be ordered against each
// other, and an ordering test that compares stdout to a call log is really
// asserting nothing. Forced Linux so the load step is a single unambiguous
// systemctl line on any host the suite runs on.
func TestStaleSweepRunsAfterTheUnitsAreLoaded(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystemFor(t, "linux")
	stubRecordingRm(t, stub)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	stale := devBinDir(home)
	seedStale(t, stale, staleOursSet())

	out, err := runStaged(t, installShPath(t), staging, home, stub)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	calls := readFile(t, filepath.Join(home, "stub-calls.log"))
	loaded := strings.Index(calls, "systemctl restart burrowee-gateway.service")
	swept := strings.Index(calls, "rm -f "+filepath.Join(stale, "burrowee-gateway"))
	if loaded < 0 {
		t.Fatalf("the units were never loaded; calls:\n%s", calls)
	}
	if swept < 0 {
		t.Fatalf("the stale copy was never removed; calls:\n%s\noutput:\n%s", calls, out)
	}
	if swept < loaded {
		t.Errorf("the sweep ran BEFORE the units were loaded — a unit still naming the per-user "+
			"path would have been executing that binary; calls:\n%s", calls)
	}
}

// stubRecordingRm puts an `rm` on the stub PATH that records its arguments in
// $STUB_LOG and then does the real thing, so removals and init-system calls
// share one ordered log.
func stubRecordingRm(t *testing.T, stub string) {
	t.Helper()
	body := "#!/bin/sh\necho \"rm $*\" >> \"$STUB_LOG\"\nexec /bin/rm \"$@\"\n"
	if err := os.WriteFile(filepath.Join(stub, "rm"), []byte(body), 0o755); err != nil {
		t.Fatalf("write stub rm: %v", err)
	}
}

// TestStaleSweepIsQuietWhenThereIsNothingToRemove — absent is success, not a
// warning. Two runs: the first sweeps, the second finds the same host already
// converged and must say nothing at all about it. A sweep that reported a
// missing file every time would put a permanent warning on every healthy host,
// which is how real warnings stop being read.
func TestStaleSweepIsQuietWhenThereIsNothingToRemove(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	stale := devBinDir(home)
	seedStale(t, stale, staleOursSet())

	if out, err := runStaged(t, installShPath(t), staging, home, stub); err != nil {
		t.Fatalf("first install failed: %v\n%s", err, out)
	}
	out, err := runStaged(t, installShPath(t), staging, home, stub)
	if err != nil {
		t.Fatalf("second install failed: %v\n%s", err, out)
	}
	if strings.Contains(out, "removed stale per-user binary") {
		t.Errorf("the second install removed something the first already had:\n%s", out)
	}
	for _, noise := range []string{"not a regular file", "carries no burrowee build stamp", "could not remove"} {
		if strings.Contains(out, noise) {
			t.Errorf("an already-converged host was warned about %q:\n%s", noise, out)
		}
	}
}
