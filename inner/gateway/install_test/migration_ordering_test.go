// Package install_test: CRITICAL 1 — the installer must not create $GW_HOME
// before the migration runner is allowed to look at it.
//
// migrations/run.sh refuses to evaluate anything when $GW_HOME does not exist,
// because every ladder input lives inside it: the version anchor is read from it
// and every --applies probe recognises the host by the shape of the tree. That
// guard is the only thing standing between `curl … | sudo sh` and a silently
// mis-targeted migration — under sudo $HOME is root's, so $GW_HOME names a tree
// the enrolled user never had.
//
// keep_installer_copy mkdir -p's $GW_HOME, and it ran BEFORE migrate_from_legacy
// in both modes. So the guard could never fire from either path: root's tree
// always existed by the time it was asked about. The observed field result was
// an ordinary-looking "no recorded version, and --applies does not recognise …",
// root-scheme units written AND loaded, the anchor written into root's tree,
// exit 0, and "next: burrowee gateway bootstrap" — followed by a daemon that hit
// GuardFreshInstallNotOrphaning and crash-looped.
package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// stageGwHomeProbe plants a migrations/run.sh that records whether $GW_HOME
// existed WHEN IT RAN, which is the only moment the answer means anything.
// Asserting afterwards would pass just as happily with the copy written first —
// which is the bug.
func stageGwHomeProbe(t *testing.T, dir, logPath string) {
	t.Helper()
	mig := filepath.Join(dir, "migrations")
	if err := os.MkdirAll(mig, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\n" +
		"_existed=no; [ -d \"$GW_HOME\" ] && _existed=yes\n" +
		"echo \"GW_HOME_EXISTED=$_existed\" >> " + shQuote(logPath) + "\n" +
		"exit 0\n"
	if err := os.WriteFile(filepath.Join(mig, "run.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

// TestFreshInstallDoesNotCreateGwHomeBeforeMigrating is the curl-pipe path.
func TestFreshInstallDoesNotCreateGwHomeBeforeMigrating(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	bundle := t.TempDir()
	seedDummyBins(t, bundle)
	script := stageInstaller(t, bundle)
	logPath := filepath.Join(t.TempDir(), "migration.log")
	stageGwHomeProbe(t, bundle, logPath)

	out, err := runStaged(t, script, bundle, home, stub)
	if err != nil {
		t.Fatalf("fresh install failed: %v\n%s", err, out)
	}

	log := migrationLog(t, logPath)
	if log == "" {
		t.Fatal("the migration never ran — this test is not exercising the ordering")
	}
	if strings.Contains(log, "GW_HOME_EXISTED=yes") {
		t.Errorf("the installer created $GW_HOME before the runner could evaluate it —\n" +
			"the runner's \"does not exist\" guard is unreachable from this path")
	}

	// The copy still has to happen, just later: `service install` re-runs
	// $GW_HOME/install.sh and resolves migrations/ beside it, so an installer
	// that stopped keeping the copy would be a different regression.
	for _, p := range []string{
		filepath.Join(home, ".burrowee", "gateway", "install.sh"),
		filepath.Join(home, ".burrowee", "gateway", "migrations", "run.sh"),
	} {
		if _, statErr := os.Stat(p); statErr != nil {
			t.Errorf("the installer copy was not kept at all: %s: %v", p, statErr)
		}
	}
}

// TestUpdateDoesNotCreateGwHomeBeforeMigrating is the same ordering on the
// console-push path, which is how most hosts in the field will reach it.
func TestUpdateDoesNotCreateGwHomeBeforeMigrating(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := binDir(home)
	logPath := filepath.Join(t.TempDir(), "migration.log")

	seedInstalled(t, binDir, withCLI(allBinsContent("v1-content"), cliWithMigrate))
	staged := withCLI(allBinsContent("v1-content"), cliWithMigrate)
	staged["burrowee-gateway"] = "gw-v2-content"
	stageDir := stageBundle(t, staged)
	script := stageInstaller(t, stageDir)
	stageGwHomeProbe(t, stageDir, logPath)

	out, err := runStagedArgs(t, script, stageDir, home, stub,
		[]string{"--version", "0.2.0"}, "BURROWEE_UPDATE=1")
	if err != nil {
		t.Fatalf("update failed: %v\n%s", err, out)
	}

	log := migrationLog(t, logPath)
	if log == "" {
		t.Fatal("the migration never ran — this test is not exercising the ordering")
	}
	if strings.Contains(log, "GW_HOME_EXISTED=yes") {
		t.Errorf("update mode created $GW_HOME before the runner could evaluate it")
	}
	if _, statErr := os.Stat(filepath.Join(home, ".burrowee", "gateway", "install.sh")); statErr != nil {
		t.Errorf("the installer copy was not kept after the migration: %v", statErr)
	}
}

// TestUpdateKeepsTheInstallerCopyOnADeferredSlot: the copy moved behind the
// migration, and the migration lives inside the own-slot branch. It must not
// have moved INSIDE that branch as well, or a host whose service slot belongs to
// another user stops getting a current installer — and `burrowee gateway service
// install --force`, the documented way to take that slot over, re-runs the copy
// at $GW_HOME.
func TestUpdateKeepsTheInstallerCopyOnADeferredSlot(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := binDir(home)
	logPath := filepath.Join(t.TempDir(), "migration.log")

	seedForeignUnit(t, home)
	seedInstalled(t, binDir, withCLI(allBinsContent("v1-content"), cliWithMigrate))
	staged := withCLI(allBinsContent("v1-content"), cliWithMigrate)
	staged["burrowee-gateway"] = "gw-v2-content"
	script, stageDir := stagedUpdateBundle(t, staged, logPath, 0)

	out, err := runStagedArgs(t, script, stageDir, home, stub,
		[]string{"--version", "0.2.7"}, "BURROWEE_UPDATE=1")
	if err != nil {
		t.Fatalf("update failed: %v\n%s", err, out)
	}
	if got := migrationLog(t, logPath); got != "" {
		t.Fatalf("migrated while another user owns the slot, so this test proves nothing:\n%s", got)
	}
	if _, statErr := os.Stat(filepath.Join(home, ".burrowee", "gateway", "install.sh")); statErr != nil {
		t.Errorf("the installer copy was lost on the deferring branch: %v", statErr)
	}
}

// ---------------------------------------------------------------------------
// MEDIUM — units-only is the fourth entry point and must write the anchor.
// ---------------------------------------------------------------------------

// TestUnitsOnlyRecordsTheVersion: the runner falls back to a migration's own
// --applies probe only when NOTHING is recorded, and with two of the four entry
// points never writing the anchor, that exceptional path became the normal one
// on most hosts in the field. `burrowee gateway service install` is the entry
// point an operator reaches for most often and it recorded nothing at all.
func TestUnitsOnlyRecordsTheVersion(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	bundle := t.TempDir()
	script := stageInstaller(t, bundle)
	logPath := filepath.Join(t.TempDir(), "migration.log")
	seedMigrateCapableCLI(t, home)
	stageMigration(t, bundle, logPath, 0)

	out, err := runStaged(t, script, home, home, stub, "BURROWEE_UNITS_ONLY=1",
		"BURROWEE_VERSION=gateway/v0.2.0.2026.08.07.4f1c3ec8")
	if err != nil {
		t.Fatalf("units-only failed: %v\n%s", err, out)
	}
	if got, want := installedVersion(t, home), "v0.2.0.2026.08.07.4f1c3ec8"; got != want {
		t.Errorf("installed-version = %q, want %q (the component prefix must be stripped)", got, want)
	}
}

// TestUnitsOnlyWithoutAVersionRecordsNothing: `service install` supplies no
// BURROWEE_VERSION today, and inventing one would be worse than none — a wrong
// anchor gates real migrations off permanently, an absent one falls back to the
// --applies probe.
func TestUnitsOnlyWithoutAVersionRecordsNothing(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	bundle := t.TempDir()
	script := stageInstaller(t, bundle)
	logPath := filepath.Join(t.TempDir(), "migration.log")
	seedMigrateCapableCLI(t, home)
	stageMigration(t, bundle, logPath, 0)

	if _, err := runStaged(t, script, home, home, stub, "BURROWEE_UNITS_ONLY=1"); err != nil {
		t.Fatalf("units-only failed: %v", err)
	}
	if v := installedVersion(t, home); v != "" {
		t.Errorf("a version was invented with none supplied: %q", v)
	}
}

// TestUnitsOnlyDoesNotRecordTheVersionOnAnUnrecordedMigration: exit 3 is
// "migrated but the receipt was lost". The receipt is what keeps a rung
// re-runnable; writing the anchor anyway closes the only remaining gate on work
// nothing on this host can prove finished.
func TestUnitsOnlyDoesNotRecordTheVersionOnAnUnrecordedMigration(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	bundle := t.TempDir()
	script := stageInstaller(t, bundle)
	logPath := filepath.Join(t.TempDir(), "migration.log")
	seedMigrateCapableCLI(t, home)
	stageMigration(t, bundle, logPath, 3)

	out, err := runStaged(t, script, home, home, stub, "BURROWEE_UNITS_ONLY=1",
		"BURROWEE_VERSION=gateway/v0.2.0")
	if err != nil {
		t.Fatalf("exit 3 from the runner must not fail units-only: %v\n%s", err, out)
	}
	if v := installedVersion(t, home); v != "" {
		t.Errorf("version recorded for an unrecorded migration: %q", v)
	}
	assertContains(t, out, "receipt could not be written")
}

// TestRecordInstalledVersionWritesBothAnchors is what survives of C1's M2
// sub-case. The $BIN_DIR copy used to be guarded on $SYS_CONFIG_DIR existing
// — "has this host been converged to the root scheme yet" — and a units-only
// run on a host without one had to leave it unwritten. Since 0.3 every mode
// establishes the whole machine-owned tree before its first write
// (ensure_system_tree), so the host IS converged by the time the version is
// recorded and both anchors are written: $GW_HOME's for the ladder, $BIN_DIR's
// for the root updater — and $BIN_DIR is now /usr/local/burrowee/bin, so the
// second anchor moved with it (spec §9.3).
//
// A host with no tree at all is not a case this can model any more: the run
// creates it. What it asserts instead is that the copy lands in the new
// $BIN_DIR and nowhere else.
func TestRecordInstalledVersionWritesBothAnchors(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)

	runInstallSh(t, home, stub,
		"BURROWEE_UNITS_ONLY=1",
		"BURROWEE_VERSION=gateway/v0.2.0.2026.08.07.4f1c3ec8",
	)

	anchor := filepath.Join(binDir(home), ".installed-version")
	if got, statErr := os.ReadFile(anchor); statErr != nil {
		t.Errorf("no root-updater anchor at %s: %v", anchor, statErr)
	} else if strings.TrimSpace(string(got)) != "v0.2.0.2026.08.07.4f1c3ec8" {
		t.Errorf("root-updater anchor = %q, want v0.2.0.2026.08.07.4f1c3ec8", strings.TrimSpace(string(got)))
	}
	if got, want := installedVersion(t, home), "v0.2.0.2026.08.07.4f1c3ec8"; got != want {
		t.Errorf("the ordinary $GW_HOME anchor was not written: got %q, want %q", got, want)
	}
}
