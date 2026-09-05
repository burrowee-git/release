// Package install_test: D3b tests for BURROWEE_UPDATE mode of install.sh.
// Tests verify per-binary sha256 change detection, transactional backup/restore,
// and the BURROWEE_CHANGED=<names> last-line contract. The fixture these
// assertions run on — binary sets, seed/stage/read helpers, install.sh runners —
// lives in update_harness_test.go.
package install_test

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestUpdateReplacesOnlyChangedBinaries verifies that when only one binary
// differs (burrowee-gateway), only that binary is replaced; the others stay
// at v1; and BURROWEE_CHANGED= names only that binary.
func TestUpdateReplacesOnlyChangedBinaries(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := binDir(home)

	// Pre-install v1 of all 5 bins.
	seedInstalled(t, binDir, allBinsContent("v1-content"))

	// Stage: only burrowee-gateway differs.
	staged := allBinsContent("v1-content")
	staged["burrowee-gateway"] = "v2-content"
	stageDir := stageBundle(t, staged)

	out := runUpdate(t, stageDir, home, stub,
		[]string{"BURROWEE_UPDATE=1"},
		"--version", "v2",
	)

	// burrowee-gateway must be the new content.
	if got := readInstalled(t, binDir, "burrowee-gateway"); got != "v2-content" {
		t.Fatalf("burrowee-gateway not updated: got %q, want v2-content", got)
	}
	// All others must remain at v1.
	for _, b := range allBins {
		if b == "burrowee-gateway" {
			continue
		}
		if got := readInstalled(t, binDir, b); got != "v1-content" {
			t.Fatalf("%s should be unchanged: got %q, want v1-content", b, got)
		}
	}

	// BURROWEE_CHANGED= must be the last occurrence and name only the changed binary.
	line := lastLineWithPrefix(out, "BURROWEE_CHANGED=")
	if line != "BURROWEE_CHANGED=burrowee-gateway" {
		t.Fatalf("change-set = %q, want BURROWEE_CHANGED=burrowee-gateway", line)
	}

	// --version must be recorded where the ladder reads it: the machine-owned
	// config root, never a home tree.
	vf := ladderAnchorPath(home)
	vb, err := os.ReadFile(vf)
	if err != nil {
		t.Fatalf("installed-version not written: %v", err)
	}
	if strings.TrimSpace(string(vb)) != "v2" {
		t.Fatalf("installed-version = %q, want v2", string(vb))
	}
}

// TestUpdateAllIdenticalIsNoop verifies that when staged content matches
// installed content for all binaries, no binary is touched and
// BURROWEE_CHANGED= is empty.
func TestUpdateAllIdenticalIsNoop(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := binDir(home)

	same := allBinsContent("identical-content")
	seedInstalled(t, binDir, same)
	stageDir := stageBundle(t, same)

	out := runUpdate(t, stageDir, home, stub, []string{"BURROWEE_UPDATE=1"})

	// All binaries must remain unchanged.
	for _, b := range allBins {
		if got := readInstalled(t, binDir, b); got != "identical-content" {
			t.Fatalf("%s modified on no-op update: got %q", b, got)
		}
	}

	// BURROWEE_CHANGED= must appear with an empty value.
	line := lastLineWithPrefix(out, "BURROWEE_CHANGED=")
	if line != "BURROWEE_CHANGED=" {
		t.Fatalf("change-set = %q, want BURROWEE_CHANGED= (empty)", line)
	}
}

// TestUpdateModeExcludesOnlyTheUpdaterBinary pins the two halves of the
// exclusion rule, which are NOT the same rule and used to be conflated.
//
// burrowee-gateway-updater is excluded because it is on its own update track:
// replacing the binary a running updater is executing from, from inside a
// script that updater launched, is the hazard the exclusion exists to prevent.
//
// burrowee-gateway-cli is NOT excluded, and the shape that excluded it is the
// release blocker. The migration calls `burrowee-gateway-cli migrate` and the
// runner probes the INSTALLED cli for that verb; leaving a 0.1.115 cli on disk
// while every binary around it advances guaranteed the probe would fail — after
// the root-scheme units were already written. gateway/update.sh has always
// carried the cli in its BINS; this is the two paths agreeing.
func TestUpdateModeExcludesOnlyTheUpdaterBinary(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := binDir(home)

	// Pre-install: the cli and the updater are OLD, all others at v1.
	installed := allBinsContent("v1-content")
	installed["burrowee-gateway-cli"] = "OLD-CLI"
	installed["burrowee-gateway-updater"] = "OLD-UPDATER"
	seedInstalled(t, binDir, installed)

	// Stage: cli, updater and gateway all differ.
	staged := allBinsContent("v1-content")
	staged["burrowee-gateway-cli"] = cliWithMigrate
	staged["burrowee-gateway-updater"] = "NEW-UPDATER"
	staged["burrowee-gateway"] = "v2-content"
	stageDir := stageBundle(t, staged)

	out := runUpdate(t, stageDir, home, stub,
		[]string{"BURROWEE_UPDATE=1"},
		"--version", "v2",
	)

	line := lastLineWithPrefix(out, "BURROWEE_CHANGED=")

	// The cli advances: named, and really swapped.
	if !strings.Contains(line, "burrowee-gateway-cli") {
		t.Errorf("update mode must place burrowee-gateway-cli; got %q", line)
	}
	if got := readInstalled(t, binDir, "burrowee-gateway-cli"); got != cliWithMigrate {
		t.Errorf("burrowee-gateway-cli was not swapped in update mode (got %q)", got)
	}

	// The updater does not: not named, and not swapped.
	if strings.Contains(line, "burrowee-gateway-updater") {
		t.Errorf("update mode must not claim burrowee-gateway-updater; got %q", line)
	}
	cur, err := os.ReadFile(filepath.Join(binDir, "burrowee-gateway-updater"))
	if err != nil {
		t.Fatalf("read burrowee-gateway-updater: %v", err)
	}
	if string(cur) != "OLD-UPDATER" {
		t.Fatalf("burrowee-gateway-updater was swapped in update mode (got %q)", cur)
	}
}

// TestUpdateModeRefusesAMissingUpdaterWithAnAccurateMessage is
// ROOT_BIN_PLACE_EXCLUDE's own consequence: BURROWEE_UPDATE mode never
// places burrowee-gateway-updater (it is on its own track), but
// render_units still verifies it before naming it in the updater unit — and
// on a host converging off the pre-collapse layout, which has NEVER had
// anything placed at $BIN_DIR/burrowee-gateway-updater, that verification
// finds an ABSENT path, not an insecure one. The refusal must say so:
// neither the stat-dialect diagnostic (which is about a stat CALL failing,
// not a file being missing) nor the generic "not root-owned" one (which
// sends an operator to check permissions on a path that was never created)
// is the right answer here.
func TestUpdateModeRefusesAMissingUpdaterWithAnAccurateMessage(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := binDir(home)
	fakeRootUID(t, stub)          // have_real_root => true, so verify_root_exec_surface actually runs
	writeStatStub(t, stub, statStubGNU) // every REAL file answers root-owned/0755; the missing updater never reaches stat at all ([ -f ] catches it first)

	// Every OTHER bin already at $BIN_DIR — the updater is the ONE name
	// genuinely absent, exactly root_bin_source/ROOT_BIN_PLACE_EXCLUDE's
	// documented converging-host case.
	installed := allBinsContent("v1-content")
	installed["burrowee-gateway-cli"] = cliWithMigrate
	delete(installed, "burrowee-gateway-updater")
	seedInstalled(t, binDir, installed)

	staged := allBinsContent("v1-content")
	staged["burrowee-gateway-cli"] = cliWithMigrate
	staged["burrowee-gateway"] = "v2-content"
	delete(staged, "burrowee-gateway-updater")
	stageDir := stageBundle(t, staged)

	out := runUpdate(t, stageDir, home, stub,
		[]string{"BURROWEE_UPDATE=1"},
		"--version", "v2",
	)

	if strings.Contains(out, "answered neither the GNU form") {
		t.Errorf("blamed the stat dialect for a file that was never there:\n%s", out)
	}
	if strings.Contains(out, "not root-owned and unwritable all the way to /") {
		t.Errorf("blamed ownership/permissions for a file that was never there:\n%s", out)
	}
	if !strings.Contains(out, filepath.Join(binDir, "burrowee-gateway-updater")+" does not exist") {
		t.Errorf("did not name the missing path accurately:\n%s", out)
	}
	if !strings.Contains(out, "service install") {
		t.Errorf("did not point at the command that converges the host:\n%s", out)
	}
	// The binary swap itself must still have succeeded — this is a units
	// refresh refusal, not a placement one (update mode's own note branch
	// already covers "service units not refreshed" for exactly this shape).
	if got := readInstalled(t, binDir, "burrowee-gateway"); got != "v2-content" {
		t.Errorf("burrowee-gateway not updated despite the units refusal: got %q", got)
	}
}

// TestUpdateModeDoesNotRestartServices verifies that update mode refreshes
// unit FILES but issues no launchctl/systemctl service operations at all —
// no bootout/bootstrap/enable/restart, and no legacy-unit migration (the
// updater restarts the kernel out-of-band; a reload here would bootout the
// running process).
func TestUpdateModeDoesNotRestartServices(t *testing.T) {
	home := t.TempDir()

	// Create a stub dir with a recording launchctl, a recording systemctl,
	// and the pass-through sudo the system unit writes go through.
	stubDir := t.TempDir()
	writeLaunchctlStub(t, stubDir)
	sysctl := "#!/bin/sh\nprintf '%s\\n' \"systemctl $*\" >> \"" + filepath.Join(stubDir, "launchctl.calls") + "\"\nexit 0\n"
	if err := os.WriteFile(filepath.Join(stubDir, "systemctl"), []byte(sysctl), 0o755); err != nil {
		t.Fatal(err)
	}
	writeSudoStub(t, stubDir)

	binDir := binDir(home)
	seedInstalled(t, binDir, allBinsContent("v1-content"))

	// Stage one changed binary so the script does real work.
	staged := allBinsContent("v1-content")
	staged["burrowee-gateway"] = "v2-content"
	stageDir := stageBundle(t, staged)

	runUpdate(t, stageDir, home, stubDir,
		[]string{"BURROWEE_UPDATE=1"},
	)

	calls, _ := os.ReadFile(filepath.Join(stubDir, "launchctl.calls"))
	callsStr := string(calls)
	for _, verb := range []string{"bootout", "bootstrap", "enable", "restart", "disable"} {
		for _, line := range strings.Split(strings.TrimRight(callsStr, "\n"), "\n") {
			if strings.Contains(line, verb) {
				t.Fatalf("update mode must not touch live services; got call: %q\nall calls:\n%s", line, callsStr)
			}
		}
	}

	// The unit FILES must still have been refreshed.
	unitPath := filepath.Join(launchdDir(home), "com.burrowee.gateway.plist")
	if runtime.GOOS != "darwin" {
		unitPath = filepath.Join(systemdDir(home), "burrowee-gateway.service")
	}
	if _, err := os.Stat(unitPath); err != nil {
		t.Errorf("update mode did not render the system unit file: %v", err)
	}
}

// TestUpdateRollsBackOnFailure verifies that when a binary cannot be placed
// mid-swap, all previously placed (and backed-up) binaries are restored to
// their original content, the script exits non-zero, and no BURROWEE_CHANGED
// line is printed.
//
// Failure injection: inject a stub `install` command (prepended to PATH) that
// succeeds on the first invocation then fails on all subsequent ones. Two
// binaries differ (burrowee-gateway first in BINS order, burrowee-gateway-
// console second) so the first placement succeeds and the second fails,
// triggering rollback of burrowee-gateway back to v1.
func TestUpdateRollsBackOnFailure(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := binDir(home)

	// Pre-install v1 of all 5 bins.
	seedInstalled(t, binDir, allBinsContent("v1-content"))

	// Stage: two binaries differ — burrowee-gateway (first in BINS) and
	// burrowee-gateway-console (third in BINS).
	staged := allBinsContent("v1-content")
	staged["burrowee-gateway"] = "gw-v2-content"
	staged["burrowee-gateway-console"] = "console-v2-content"
	stageDir := stageBundle(t, staged)

	// Write a stub `install` into the stub dir. It uses a counter file to
	// succeed on the first call (placing burrowee-gateway) and fail on the
	// second changed binary (burrowee-gateway-console), triggering rollback.
	counterFile := filepath.Join(stub, "install.counter")
	installStub := filepath.Join(stub, "install")
	installStubContent := "#!/bin/sh\n" +
		"count=0\n" +
		"if [ -f \"" + counterFile + "\" ]; then count=$(cat \"" + counterFile + "\"); fi\n" +
		"count=$((count + 1))\n" +
		"printf '%s' \"$count\" > \"" + counterFile + "\"\n" +
		"if [ \"$count\" -gt 1 ]; then exit 1; fi\n" +
		// On first call, perform the actual install: last two args are src and dst.
		"src=\"\"; dst=\"\"\n" +
		"while [ $# -gt 0 ]; do prev=\"$dst\"; dst=\"$1\"; src=\"$prev\"; shift; done\n" +
		"cp \"$src\" \"$dst\" && chmod 0755 \"$dst\"\n"
	if err := os.WriteFile(installStub, []byte(installStubContent), 0o755); err != nil {
		t.Fatalf("write install stub: %v", err)
	}

	out := runUpdateExpectFail(t, stageDir, home, stub,
		[]string{"BURROWEE_UPDATE=1"},
	)

	// burrowee-gateway must be rolled back to its original v1 content.
	if got := readInstalled(t, binDir, "burrowee-gateway"); got != "v1-content" {
		t.Fatalf("burrowee-gateway not rolled back: got %q, want v1-content", got)
	}

	// No BURROWEE_CHANGED= line must appear in the output.
	if line := lastLineWithPrefix(out, "BURROWEE_CHANGED="); line != "" {
		t.Fatalf("BURROWEE_CHANGED line printed on failure: %q", line)
	}
}

// TestUpdateUnitWriteFailurePrintsSudoAdvisory verifies that when the system
// unit content changed but the privileged write fails (no usable sudo), update
// mode prints the needs-sudo advisory instead of a false "service unit:"
// success line, and the binary swap itself still succeeds.
func TestUpdateUnitWriteFailurePrintsSudoAdvisory(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := binDir(home)

	// An update runs on an INSTALLED host, whose machine-owned tree already
	// exists at its stated modes; ensure_system_tree then needs no
	// elevation, and the failing sudo below is reached only by the unit
	// write it is about. Without the tree the run would refuse to create it
	// unprivileged — correct, but a different claim from this test's.
	seedStatedSystemTree(t, home)
	seedInstalled(t, binDir, allBinsContent("v1-content"))
	staged := allBinsContent("v1-content")
	staged["burrowee-gateway"] = "gw-v2-content"
	stageDir := stageBundle(t, staged)

	// No unit file exists in the sandboxed unit dir, so render_units must take
	// the privileged write path — and this sudo always fails.
	failing := "#!/bin/sh\necho \"sudo $*\" >> \"$STUB_LOG\"\nexit 1\n"
	if err := os.WriteFile(filepath.Join(stub, "sudo"), []byte(failing), 0o755); err != nil {
		t.Fatalf("write failing sudo: %v", err)
	}

	out := runUpdate(t, stageDir, home, stub, []string{"BURROWEE_UPDATE=1"})

	if !strings.Contains(out, "service units not refreshed (needs sudo)") {
		t.Errorf("needs-sudo advisory not printed; output:\n%s", out)
	}

	unitPath := filepath.Join(launchdDir(home), "com.burrowee.gateway.plist")
	if runtime.GOOS != "darwin" {
		unitPath = filepath.Join(systemdDir(home), "burrowee-gateway.service")
	}
	if strings.Contains(out, "service unit: "+unitPath) {
		t.Errorf("false unit success line printed despite failed write; output:\n%s", out)
	}
	if _, err := os.Stat(unitPath); err == nil {
		t.Errorf("unit file written despite failing sudo")
	}

	if got := readInstalled(t, binDir, "burrowee-gateway"); got != "gw-v2-content" {
		t.Errorf("binary swap should still succeed: got %q", got)
	}
}

// TestUpdateForceReplacesIdenticalBinaries pins the BURROWEE_FORCE=1 branch,
// which INVERTS what TestUpdateAllIdenticalIsNoop pins and shipped with no test
// of its own. `gateway update --force` onto the already-installed version has
// byte-identical binaries, so the sha256 diff would place nothing and the
// operator's "reinstall completely" would be a silent no-op.
//
// Two halves, and the second is the one a careless test misses: --force must
// re-place every SERVE binary, and must STILL skip burrowee-gateway-updater.
// FORCE bypasses the sha256 check, not the ownership rule — the updater is
// updated out-of-band, and re-placing it from inside a script the updater is
// running is exactly what the exclusion exists to prevent.
func TestUpdateForceReplacesIdenticalBinaries(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := binDir(home)

	// Installed and staged content are IDENTICAL for every binary — without
	// FORCE this is the no-op case (TestUpdateAllIdenticalIsNoop).
	same := withCLI(allBinsContent("identical-content"), cliWithMigrate)
	seedInstalled(t, binDir, same)
	stageDir := stageBundle(t, same)

	// Mark the updater-owned binary so a swap would be detectable even though
	// the staged bytes match: if update mode places it, the installed file
	// loses this marker.
	seedInstalled(t, binDir, map[string]string{"burrowee-gateway-updater": "UPDATER-OWNED"})

	out := runUpdate(t, stageDir, home, stub,
		[]string{"BURROWEE_UPDATE=1", "BURROWEE_FORCE=1"},
		"--version", "v2",
	)

	// Half 1: every serve binary is named, in BINS order.
	line := lastLineWithPrefix(out, "BURROWEE_CHANGED=")
	want := "BURROWEE_CHANGED=" + strings.Join(serveBins, " ")
	if line != want {
		t.Fatalf("change-set = %q, want %q\noutput:\n%s", line, want, out)
	}

	// Half 2: burrowee-gateway-updater is STILL omitted — FORCE bypasses the
	// sha256 check, not the ownership rule.
	if strings.Contains(line, "burrowee-gateway-updater") {
		t.Errorf("--force must not claim burrowee-gateway-updater: %q", line)
	}
	if got := readInstalled(t, binDir, "burrowee-gateway-updater"); got != "UPDATER-OWNED" {
		t.Errorf("--force swapped burrowee-gateway-updater (content %q) — it is updated out-of-band", got)
	}

	// And the placement really happened: each serve binary is present and
	// executable after the forced re-place, not merely listed.
	for _, b := range serveBins {
		info, err := os.Stat(filepath.Join(binDir, b))
		if err != nil {
			t.Errorf("serve binary %s missing after --force: %v", b, err)
			continue
		}
		if info.Mode().Perm()&0o111 == 0 {
			t.Errorf("serve binary %s is not executable after --force: %v", b, info.Mode())
		}
	}

	// No backup files may survive a successful forced update.
	entries, err := os.ReadDir(binDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.Contains(e.Name(), ".bak-") {
			t.Errorf("backup file left behind after a successful --force: %s", e.Name())
		}
	}
}

// stagedUpdateBundle builds an update-mode bundle that also carries the
// installer and a fake migration, so the hand-off can be asserted: binaries in
// cwd, install.sh beside migrations/v0_1_to_v0_2.sh (install.sh resolves the
// migration relative to its own path, not cwd).
func stagedUpdateBundle(t *testing.T, contents map[string]string, logPath string, migrateExit int) (script, stageDir string) {
	t.Helper()
	stageDir = stageBundle(t, contents)
	script = stageInstaller(t, stageDir)
	stageMigration(t, stageDir, logPath, migrateExit)
	return script, stageDir
}

// TestUpdateKeepsTheInstallerCopyWhereRootCanRunIt: `service install` re-runs a
// kept install.sh, and the runner is resolved beside whichever install.sh is
// executing — so a kept copy without a current migrations/ beside it is a stale
// unit-writer that also cannot migrate. The copy must therefore still happen on
// this path; what changed is WHERE.
//
// It is the root-owned $BIN_DIR copy, placed by ensure_root_exec_surface, and
// there is no longer a second one under the operator's home. The per-user copy
// mkdir -p'd $GW_HOME, which is both a root write into a human's home and the
// thing that destroyed the 0.2→0.3 rung's "$GW_HOME does not exist" evidence —
// this test's own probe (KEPT_INSTALLER, recorded from inside the migration)
// still pins that the tree is absent when the runner looks.
func TestUpdateKeepsTheInstallerCopyWhereRootCanRunIt(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := binDir(home)
	logPath := filepath.Join(t.TempDir(), "migration.log")

	seedInstalled(t, binDir, withCLI(allBinsContent("v1-content"), cliWithMigrate))
	staged := withCLI(allBinsContent("v1-content"), cliWithMigrate)
	staged["burrowee-gateway"] = "gw-v2-content"
	script, stageDir := stagedUpdateBundle(t, staged, logPath, 0)

	out, err := runStaged(t, script, stageDir, home, stub, "BURROWEE_UPDATE=1")
	if err != nil {
		t.Fatalf("install.sh update failed: %v\n%s", err, out)
	}

	// Recorded from INSIDE the migration: nothing of ours is in $GW_HOME while
	// the rung is deciding what to adopt.
	log := migrationLog(t, logPath)
	if log == "" {
		t.Fatal("the migration never ran")
	}
	assertContains(t, log, "KEPT_INSTALLER=no")

	// And the root-owned copy must be in place by the end of the run, or
	// `service install` has no current installer to re-run.
	for _, p := range []string{
		filepath.Join(binDir, "install.sh"),
		filepath.Join(binDir, "migrations", "run.sh"),
	} {
		if _, statErr := os.Stat(p); statErr != nil {
			t.Errorf("the root-owned installer copy was not kept: %s: %v", p, statErr)
		}
	}
	assertOperatorHomeUntouched(t, home)
}

// TestUpdateRecordsTheVersionOnlyAfterMigrating: recording it first means a failed
// migration leaves the NEW version on disk beside the OLD layout, after which the
// runner's gate reads "already up to date" and the host never migrates again.
func TestUpdateRecordsTheVersionOnlyAfterMigrating(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := binDir(home)
	logPath := filepath.Join(t.TempDir(), "migration.log")

	seedInstalled(t, binDir, withCLI(allBinsContent("v1-content"), cliWithMigrate))
	staged := withCLI(allBinsContent("v1-content"), cliWithMigrate)
	staged["burrowee-gateway"] = "gw-v2-content"
	script, stageDir := stagedUpdateBundle(t, staged, logPath, 1) // migration FAILS

	out, err := runStagedArgs(t, script, stageDir, home, stub,
		[]string{"--version", "0.2.0"}, "BURROWEE_UPDATE=1")
	if err == nil {
		t.Fatalf("install.sh update succeeded despite a failing migration:\n%s", out)
	}

	versionFile := filepath.Join(home, ".burrowee", "gateway", ".installed-version")
	if b, readErr := os.ReadFile(versionFile); readErr == nil {
		t.Errorf("version recorded despite the failed migration: %q", string(b))
	}
}

// TestUpdateReportsAStoppedGatewayAfterMigrating: update mode renders unit files
// but never loads them, so it has no start step of its own. The runner's exit 2
// means it stopped the gateway — say so rather than leaving the operator to find a
// dead service.
func TestUpdateReportsAStoppedGatewayAfterMigrating(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := binDir(home)
	logPath := filepath.Join(t.TempDir(), "migration.log")

	seedInstalled(t, binDir, withCLI(allBinsContent("v1-content"), cliWithMigrate))
	staged := withCLI(allBinsContent("v1-content"), cliWithMigrate)
	staged["burrowee-gateway"] = "gw-v2-content"
	script, stageDir := stagedUpdateBundle(t, staged, logPath, 2) // "migrations ran"

	out, err := runStaged(t, script, stageDir, home, stub, "BURROWEE_UPDATE=1")
	if err != nil {
		t.Fatalf("exit 2 from the runner must not fail the update: %v\n%s", err, out)
	}
	if !strings.Contains(out, "stopped the gateway") {
		t.Errorf("no notice that the gateway is down:\n%s", out)
	}
	// The change-set line still has to be last on stdout — core parses it.
	if got := lastLineWithPrefix(out, "BURROWEE_CHANGED="); got == "" {
		t.Errorf("BURROWEE_CHANGED line missing:\n%s", out)
	}
}

// TestUpdateSkipsTheMigrationForForeignSlot is the wrong-identity guard. Update
// mode has no consent prompt and already refuses to touch a unit slot recorded
// for another user; migrating is the same class of claim — whose identity the
// root daemon adopts — so it must defer too. Adopting this user's tree while
// another owns the service would hand the daemon the wrong identity, and a node
// re-registering under a new relay_ed.key is not quietly undone.
func TestUpdateSkipsTheMigrationForForeignSlot(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := binDir(home)
	logPath := filepath.Join(t.TempDir(), "migration.log")

	seedForeignUnit(t, home)
	seedInstalled(t, binDir, withCLI(allBinsContent("v1-content"), cliWithMigrate))
	staged := withCLI(allBinsContent("v1-content"), cliWithMigrate)
	staged["burrowee-gateway"] = "gw-v2-content"
	script, stageDir := stagedUpdateBundle(t, staged, logPath, 0)

	out, err := runStaged(t, script, stageDir, home, stub, "BURROWEE_UPDATE=1")
	if err != nil {
		t.Fatalf("install.sh update failed: %v\n%s", err, out)
	}

	if got := migrationLog(t, logPath); got != "" {
		t.Errorf("migrated while user 'someone-else' owns the slot:\n%s", got)
	}
	if !strings.Contains(out, "not migrating either") {
		t.Errorf("no explanation of the deferral:\n%s", out)
	}
	// The binary swap is independent and must still complete.
	if got := readInstalled(t, binDir, "burrowee-gateway"); got != "gw-v2-content" {
		t.Errorf("binary swap should still succeed: got %q", got)
	}
}
