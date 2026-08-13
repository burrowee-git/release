// stale_user_bins_test.go — the sweep of the per-user binaries an EARLIER,
// unprivileged edge install left behind (install.sh: remove_stale_user_bins).
//
// The unprivileged branch that filled $HOME/.local/bin is gone (root_only_test.go),
// so on a production host that directory can only ever be a stale tree — but the
// sweep's "never delete what this install just made" guard is still live code,
// because SYS_BIN_DIR redirects the destination and that redirect is the only
// reason this sweep is testable at all. A guard nothing exercises is a guard
// nobody knows still works, so the last test in this file points the destination
// AT the per-user dir and requires the freshly placed binaries to survive.
//
// EVERY PATH HERE IS A FIXTURE TREE under t.TempDir(). Nothing in this file may
// resolve to a real $HOME/.local/bin — the machines this suite runs on have
// live burrowee installs in exactly that directory.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// staleBinFixture stands in for a real burrowee binary: NUL bytes and an ELF
// header around the module path the Go toolchain stamps into every
// github.com/burrowee-git/* executable's build-info blob.
//
// The NULs are load-bearing. install.sh decides ownership with `grep -qF` over
// the file, and that approach rests on matching BINARY content — a plain-text
// fixture would prove the predicate matches a string, which was never in doubt.
func staleBinFixture(name string) []byte {
	return []byte("\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00" +
		"go1.26.5\x00path\tgithub.com/burrowee-git/edge/cmd/" + name + "\x00\x00\n")
}

// foreignFile is a file that is NOT ours: an operator's own script, of the kind
// that shares a name or a prefix with what this component installs.
const foreignFile = "#!/bin/sh\n# my own wrapper — nothing to do with the vendor\nexec /opt/local/thing \"$@\"\n"

// staleDir is the per-user bin dir an unprivileged edge install writes to, and
// so the tree a later root install has to sweep.
func staleDir(home string) string { return filepath.Join(home, ".local", "bin") }

// seedStale writes name→content into dir, creating it.
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

// staleOursSet is every name in $BINS, each as a convincing burrowee binary.
func staleOursSet() map[string][]byte {
	files := map[string][]byte{}
	for _, b := range edgeBins {
		files[b] = staleBinFixture(b)
	}
	return files
}

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

// sandboxLaunchd keeps unit_naming_dir's scan inside the sandbox: its default
// is the REAL /Library/LaunchDaemons, which exists on a macOS dev machine and
// is not this suite's to read.
func sandboxLaunchd(home string) string {
	return "LAUNCHD_PLIST_DIR=" + filepath.Join(home, "LaunchDaemons")
}

// TestEdgeRootInstallSweepsStalePerUserBinaries is the headline claim: a root
// install removes the copies an earlier unprivileged install left shadowing
// /usr/local/bin on PATH, reports each one, and leaves what it just installed.
func TestEdgeRootInstallSweepsStalePerUserBinaries(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	stale := staleDir(home)
	seedStale(t, stale, staleOursSet())

	sysBinDir, _, out := runRootInstall(t, home, staging, sandboxLaunchd(home))

	for _, b := range edgeBins {
		assertGone(t, filepath.Join(stale, b), "the stale per-user copy still shadows the system bin dir on PATH")
		assertPresent(t, filepath.Join(sysBinDir, b), "the sweep took the binary this run installed")
		assertContains(t, out, "removed stale per-user binary: "+filepath.Join(stale, b))
	}
}

// TestEdgeStaleSweepNeverTakesTheDirectoryItJustFilled — the one outcome that
// would be unforgivable, and the reason install.sh's `$_rsb_dir = $BIN_DIR`
// guard survived the collapse rather than being deleted as dead.
//
// It cannot be reached with the PRODUCTION destination (/usr/local/bin is
// nobody's ~/.local/bin) — but SYS_BIN_DIR redirects it, every test in this file
// depends on that redirect, and a sweep that ran on its own destination would
// delete the binaries the same run had just placed. The failure would look like
// a successful install of nothing.
//
// NOT seedEdgeBins for the staging tree: its stubs are shell scripts carrying no
// build stamp, so is_burrowee_binary would decline them and this test would pass
// on the strength of a check that has nothing to do with what it claims. On a
// real host the binaries being placed ARE ours, and the destination guard is the
// only thing between them and the sweep — so the bundle has to look ours.
func TestEdgeStaleSweepNeverTakesTheDirectoryItJustFilled(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedStale(t, staging, staleOursSet())

	// The destination IS the per-user dir for this run.
	dest := staleDir(home)
	stub := stubRootEnv(t)
	unitDir := filepath.Join(home, "systemd-system")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("sh", installShPath(t))
	cmd.Dir = staging
	cmd.Env = []string{
		"HOME=" + home,
		"PATH=" + stub + ":/usr/bin:/bin",
		"STUB_LOG=" + filepath.Join(home, "stub-calls.log"),
		"SYS_BIN_DIR=" + dest,
		"SYSTEMD_UNIT_DIR=" + unitDir,
		"ROOT_HOME=" + filepath.Join(home, "root-home"),
		sandboxLaunchd(home),
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	for _, b := range edgeBins {
		assertPresent(t, filepath.Join(dest, b),
			"the sweep deleted a binary this very run had just placed")
	}
	if strings.Contains(string(out), "removed stale per-user binary") {
		t.Errorf("the sweep ran on this run's own destination:\n%s", out)
	}
}

// TestEdgeStaleSweepUsesTheOperatorHomeNotDollarHome — the trap: the documented
// flow is `curl … | sudo sh`, where $HOME is root's, so a sweep written against
// $HOME looks in a tree no unprivileged install ever wrote to. It finds
// nothing, prints nothing, exits 0, and every shadowing copy survives.
func TestEdgeStaleSweepUsesTheOperatorHomeNotDollarHome(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)

	// An account resolvable ONLY through the LEGACY_HOME_PARENTS fallback, so
	// this test can never reach a real account's home.
	parents := t.TempDir()
	operator := "burrowee-fixture-operator"
	operatorStale := filepath.Join(parents, operator, ".local", "bin")
	seedStale(t, operatorStale, staleOursSet())

	// $HOME's own per-user tree, which must be left alone.
	homeStale := staleDir(home)
	seedStale(t, homeStale, map[string][]byte{"burrowee-edge": staleBinFixture("burrowee-edge")})

	_, _, out := runRootInstall(t, home, staging,
		sandboxLaunchd(home),
		"SUDO_USER="+operator,
		"BURROWEE_LEGACY_HOME_PARENTS="+parents)

	for _, b := range edgeBins {
		assertGone(t, filepath.Join(operatorStale, b),
			"the sweep did not resolve $SUDO_USER's home — under sudo $HOME is root's, so this is the tree that matters")
	}
	assertPresent(t, filepath.Join(homeStale, "burrowee-edge"),
		"the sweep swept $HOME instead of the operator's home")
	assertContains(t, out, "removed stale per-user binary: "+filepath.Join(operatorStale, "burrowee-edge"))
}

// TestEdgeStaleSweepSkipsWhenAUnitStillNamesThePerUserDir — the ordering guard
// as a refusal: another component's unit can still point into the per-user
// tree, and removing a binary a loaded unit names stops the daemon rather than
// merely staling its next restart.
func TestEdgeStaleSweepSkipsWhenAUnitStillNamesThePerUserDir(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	stale := staleDir(home)
	seedStale(t, stale, staleOursSet())

	unitDir := filepath.Join(home, "systemd-system")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	foreignUnit := filepath.Join(unitDir, "burrowee-relay.service")
	if err := os.WriteFile(foreignUnit,
		[]byte("[Service]\nExecStart="+stale+"/burrowee-relay run\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	_, _, out := runRootInstall(t, home, staging, sandboxLaunchd(home))

	for _, b := range edgeBins {
		assertPresent(t, filepath.Join(stale, b),
			"a unit still names that directory, so removing from it can stop a running daemon")
	}
	assertContains(t, out, foreignUnit, "still names "+stale)
	if strings.Contains(out, "removed stale per-user binary") {
		t.Errorf("something was removed despite a live reference:\n%s", out)
	}
}

// TestEdgeStaleSweepLeavesWhatIsNotOurs — the bar for deleting from a user's
// home is "provably ours", not "named like ours": an operator's own file that
// takes one of our exact names, and one that merely shares the prefix (the file
// a `rm ~/.local/bin/burrowee*` would have taken).
func TestEdgeStaleSweepLeavesWhatIsNotOurs(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	stale := staleDir(home)
	seedStale(t, stale, map[string][]byte{
		"burrowee-edge":     staleBinFixture("burrowee-edge"),
		"burrowee-edge-cli": []byte(foreignFile),
		"burrowee-notes":    []byte(foreignFile),
	})

	_, _, out := runRootInstall(t, home, staging, sandboxLaunchd(home))

	assertGone(t, filepath.Join(stale, "burrowee-edge"), "it carries our build stamp and is ours to remove")
	assertPresent(t, filepath.Join(stale, "burrowee-edge-cli"),
		"it carries no burrowee build stamp — a same-named file that is not ours must survive")
	assertPresent(t, filepath.Join(stale, "burrowee-notes"),
		"it is not in $BINS at all — the sweep must never glob")
	assertContains(t, out, filepath.Join(stale, "burrowee-edge-cli")+" carries no burrowee build stamp")
}

// TestEdgeStaleSweepKeepsTheDispatcherWhileAnotherComponentIsInstalledThere —
// the bare `burrowee` dispatcher is shared, and the cli component still
// installs per-user by design.
func TestEdgeStaleSweepKeepsTheDispatcherWhileAnotherComponentIsInstalledThere(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	stale := staleDir(home)
	files := staleOursSet()
	files["burrowee-cli"] = staleBinFixture("burrowee-cli")
	seedStale(t, stale, files)

	_, _, out := runRootInstall(t, home, staging, sandboxLaunchd(home))

	assertPresent(t, filepath.Join(stale, "burrowee"),
		"the cli is still installed there and the dispatcher is shared")
	assertPresent(t, filepath.Join(stale, "burrowee-cli"), "it belongs to another component")
	assertGone(t, filepath.Join(stale, "burrowee-edge"), "edge's own binaries still move")
	assertContains(t, out, "kept "+filepath.Join(stale, "burrowee")+" (dispatcher)")
}
