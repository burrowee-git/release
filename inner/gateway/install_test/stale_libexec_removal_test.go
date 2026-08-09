// stale_libexec_removal_test.go — converging a host off the pre-collapse
// /usr/local/libexec/burrowee/gateway tree, and the ORDER that makes it safe.
//
// remove_stale_libexec_tree must run ONLY after render_units has rewritten the
// unit to name $BIN_DIR and load_units has actually reloaded/bootstrapped it
// into the live supervisor — never before. A host converging off the old
// layout has its supervisor holding the OLD in-memory ExecStart (the one
// naming the stale tree) right up until that reload happens; removing the
// tree earlier would not be cleanup, it would be pulling the binary out from
// under a supervisor that still intends to exec it on the next KeepAlive or
// Restart cycle.
package install_test

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// seedStaleLibexecHost stages a host whose unit still names the pre-collapse
// tree: the unit file, and the tree itself (holding a live-looking
// burrowee-gateway), placed under a throwaway temp dir the caller redirects
// BURROWEE_OLD_ROOT_EXEC_DIR to — nothing here ever touches the real
// /usr/local/libexec on the host running the suite. Returns that path.
func seedStaleLibexecHost(t *testing.T, home string) (staleDir string) {
	t.Helper()
	seedMigrateCapableCLI(t, home)
	staleDir = filepath.Join(t.TempDir(), "libexec", "burrowee", "gateway")
	if err := os.MkdirAll(staleDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, b := range rootExecedBins {
		if err := os.WriteFile(filepath.Join(staleDir, b), []byte("stale-"+b+"\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(staleDir, "install.sh"), []byte("#!/bin/sh\n# stale installer\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	unit := coreUnitPath(home)
	if err := os.MkdirAll(filepath.Dir(unit), 0o755); err != nil {
		t.Fatal(err)
	}
	stalePath := filepath.Join(staleDir, "burrowee-gateway")
	content := "[Unit]\nDescription=burrowee-gateway\n\n[Service]\nExecStart=" + stalePath + " --no-open\nRestart=always\n"
	if strings.HasSuffix(unit, ".plist") {
		content = "<plist version=\"1.0\"><dict>\n  <key>Label</key><string>com.burrowee.gateway</string>\n" +
			"  <key>ProgramArguments</key><array><string>" + stalePath + "</string><string>--no-open</string></array>\n</dict></plist>\n"
	}
	if err := os.WriteFile(unit, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return staleDir
}

// TestInstallShConvergesAHostOffTheStaleLibexecTree is the acceptance test:
// after `burrowee gateway service install` on a host still carrying the
// pre-collapse unit, the unit names $BIN_DIR and the stale tree is gone.
func TestInstallShConvergesAHostOffTheStaleLibexecTree(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staleDir := seedStaleLibexecHost(t, home)

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1", "BURROWEE_OLD_ROOT_EXEC_DIR="+staleDir)

	got := readFile(t, coreUnitPath(home))
	if strings.Contains(got, staleDir) {
		t.Errorf("the unit still names the stale tree after a repair run:\n%s", got)
	}
	assertContains(t, got, filepath.Join(binDir(home), "burrowee-gateway"))

	if _, statErr := os.Stat(staleDir); statErr == nil {
		t.Errorf("the stale tree %s survived the run", staleDir)
	}
}

// TestInstallShRemovesTheStaleTreeOnlyAfterLoad is the ORDER proof: the
// shared stub-call log (sudo/launchctl/systemctl all append to it, in the
// order install.sh actually issued them) is read for "load happened before
// removal" empirically, not asserted from the outcome alone.
func TestInstallShRemovesTheStaleTreeOnlyAfterLoad(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staleDir := seedStaleLibexecHost(t, home)

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1", "BURROWEE_OLD_ROOT_EXEC_DIR="+staleDir)

	log := readFile(t, filepath.Join(home, "stub-calls.log"))
	loadIdx := firstLineIndexContaining(log, loadMarker())
	removeIdx := firstLineIndexContaining(log, "rm -rf "+staleDir)
	if loadIdx < 0 {
		t.Fatalf("the unit was never (re)loaded into the supervisor — this test cannot prove an order that never happened:\n%s", log)
	}
	if removeIdx < 0 {
		t.Fatalf("the stale tree was never removed:\n%s", log)
	}
	if removeIdx < loadIdx {
		t.Errorf("the stale tree was removed BEFORE the unit was loaded (log line %d) — full log:\n%s", removeIdx, log)
	}
}

// loadMarker is the stub-log substring that proves the unit was handed to the
// live supervisor, matching serviceStartCall's platform split.
func loadMarker() string {
	if runtime.GOOS == "darwin" {
		return "launchctl bootstrap system"
	}
	return "systemctl enable --now burrowee-gateway.service"
}

// firstLineIndexContaining returns the 1-based line number of the first line
// in log containing want, or -1.
func firstLineIndexContaining(log, want string) int {
	for i, line := range strings.Split(log, "\n") {
		if strings.Contains(line, want) {
			return i + 1
		}
	}
	return -1
}

// TestInstallShNeverRemovesAMissingStaleTree is the anti-vacuity partner: a
// host that never had the pre-collapse layout must not have this cleanup step
// invent work (or, worse, an elevated call) where there is nothing to do.
func TestInstallShNeverRemovesAMissingStaleTree(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)
	absent := filepath.Join(t.TempDir(), "never-existed")

	out := runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1", "BURROWEE_OLD_ROOT_EXEC_DIR="+absent)
	if strings.Contains(out, "removed the superseded") {
		t.Errorf("claimed to remove a tree that was never there:\n%s", out)
	}
	log := readFile(t, filepath.Join(home, "stub-calls.log"))
	if strings.Contains(log, "rm -rf "+absent) {
		t.Errorf("issued an rm -rf for a tree that was never there:\n%s", log)
	}
}
