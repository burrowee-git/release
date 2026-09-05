// Package install_test: CRITICAL 1 — the installer must not create $GW_HOME
// AT ALL, and the 0.2→0.3 rung must still see the tree it migrates from.
//
// The 0.2→0.3 rung refuses to adopt anything when $GW_HOME does not exist,
// because that tree is what it copies the host's identity out of. That
// evidence is the only thing standing between `curl … | sudo sh` and a
// silently mis-targeted migration.
//
// keep_installer_copy mkdir -p'd $GW_HOME, and it ran BEFORE
// migrate_from_legacy in both modes. So the guard could never fire from either
// path: the tree always existed by the time it was asked about. The observed
// field result was an ordinary-looking "no recorded version, and --applies does
// not recognise …", root-scheme units written AND loaded, the anchor written
// into a home tree, exit 0, and "next: burrowee gateway bootstrap" — followed
// by a daemon that hit GuardFreshInstallNotOrphaning and crash-looped.
//
// The ordering fix moved the copy behind the migration. THIS feature deletes
// the copy, so the tests below assert the stronger property: the runner sees an
// absent $GW_HOME, and it is still absent when the installer exits.
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

	// And it is STILL absent when the run ends — the copy that used to create
	// it is gone, not merely reordered behind the runner.
	assertOperatorHomeUntouched(t, home)

	// The kept installer a later `service install` runs is the root-owned one.
	for _, p := range []string{
		filepath.Join(binDir(home), "install.sh"),
		filepath.Join(binDir(home), "migrations", "run.sh"),
	} {
		if _, statErr := os.Stat(p); statErr != nil {
			t.Errorf("the root-owned installer copy was not kept: %s: %v", p, statErr)
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
	assertOperatorHomeUntouched(t, home)
	if _, statErr := os.Stat(filepath.Join(binDir, "install.sh")); statErr != nil {
		t.Errorf("the root-owned installer copy was not kept after the migration: %v", statErr)
	}
}

// TestUpdateOnADeferredSlotWritesNothingUnderTheOperatorHome: the branch that
// defers — another user owns the service slot — used to be the one place a
// reader might argue the per-user copy was still owed, because it is the branch
// that skips the migration and the units alike. It is not owed: nothing this
// installer leaves behind belongs in somebody's home, on any branch.
func TestUpdateOnADeferredSlotWritesNothingUnderTheOperatorHome(t *testing.T) {
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
	assertOperatorHomeUntouched(t, home)
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
// creates it. What it asserts instead is that both copies land in the two
// MACHINE-OWNED roots and nowhere else.
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
		t.Errorf("the ladder anchor at %s was not written: got %q, want %q", ladderAnchorPath(home), got, want)
	}
	assertOperatorHomeUntouched(t, home)
}
