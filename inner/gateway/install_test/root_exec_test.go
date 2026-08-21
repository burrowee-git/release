// root_exec_test.go — the PRIVILEGED EXECUTION SURFACE ($BIN_DIR).
//
// 0.2.0 moved the gateway's services to root but left the binaries they name in
// ${PREFIX:-$HOME/.local}/bin, which made every one of those units a standing
// uid-0 grant to the installing user: overwrite the file, wait for a reboot, a
// KeepAlive cycle or a pushed update. These tests are about the directory that
// fixes it and, just as much, about the refusals that keep a unit from ever
// naming anything else.
//
// SINCE THE LIBEXEC-TO-$BIN_DIR COLLAPSE (2026-08-08) this is one directory,
// not two, and since the prefix collapse (2026-08-13) there is one flow into
// it, not two: $BIN_DIR is root-owned, always, and a set PREFIX is refused
// outright. Every test in this file therefore runs under installShEnv's
// BURROWEE_BIN_DIR redirect and asserts against binDir(home) — the root-secure
// ANCESTOR WALK, not a second directory, is what makes that safe in
// production, and this file proves the walk's placement/refusal behavior, not
// its ownership verdict (bin_dir_elevation_test.go and core/binary's
// IsRootSecure suite own that).
package install_test

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// rootExecedBins is install.sh's ROOT_BINS: everything a root process execs with
// no operator present.
var rootExecedBins = []string{
	"burrowee-gateway",
	"burrowee-gateway-console",
	"burrowee-gateway-updater",
	"burrowee-gateway-cli",
}

// TestInstallShPlacesTheRootExecedBinariesInBinDir checks the placement half:
// every binary a root process execs unattended lands in $BIN_DIR, together
// with the installer the root updater re-runs — GENUINELY placed, not merely
// present beforehand: the fixture seeds at devBinDir(home) (the historical
// per-user default), not binDir(home), so $BIN_DIR starts EMPTY and this
// only passes if ensure_root_exec_surface actually copied everything there.
//
// UNPROVABLE HERE, AND DELIBERATELY NOT PRETENDED OTHERWISE: before the
// collapse this test also asserted burrowee/burrowee-register were ABSENT
// from the privileged tree — a real property back when that tree was
// separate from $BIN_DIR. Now every one of the six BINS, root-execed or not,
// correctly shares $BIN_DIR (see install.sh's ROOT_BINS comment), so an
// absence-from-directory check would be actively wrong to assert: this exact
// fixture (BURROWEE_UNITS_ONLY, no bundle) happens not to place burrowee/
// burrowee-register at all (ensure_root_exec_surface only ever touches
// ROOT_BINS), but a fresh install legitimately puts them right beside the
// four checked here. What survives, and is worth proving, is narrower: which
// paths the root-secure walk GATES before a unit may name them — asserted
// directly in TestInstallShRefusesAPrivilegedTreeItCannotProveIsRootOwned.
func TestInstallShPlacesTheRootExecedBinariesInBinDir(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLIAtDevBinDir(t, home)

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	for _, name := range append(rootExecedBins, "install.sh") {
		if _, err := os.Stat(filepath.Join(binDir(home), name)); err != nil {
			t.Errorf("%s missing from $BIN_DIR: %v", name, err)
		}
	}
}

// TestInstallShKeepsTheBinDirComplete: every binary lands in $BIN_DIR — it is
// what PATH resolves, what an operator runs, and what a root consumer names
// absolutely. All six or none; a partial set is what the unit-writing steps
// immediately after placement would mistake for a complete install.
//
// This used to be the per-user-flow guard, run with an explicit PREFIX. That
// flow is gone (bin_dir_default_test.go), so the same completeness claim is now
// made about the one destination there is.
func TestInstallShKeepsTheBinDirComplete(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)

	runInstallShFrom(t, staging, home, stub)

	for _, name := range allBins {
		if _, err := os.Stat(filepath.Join(binDir(home), name)); err != nil {
			t.Errorf("%s missing from $BIN_DIR: %v", name, err)
		}
	}
}

// TestInstallShRefusesToWriteAUnitItCannotBackWithARootOwnedBinary is the
// refusal that matters most, because its failure mode is silent: a unit is
// durable, the supervisor execs what it names as root at every boot, and
// nothing rewrites it until an install runs again. There is no retry that
// undoes a bad one, so the only correct moment to refuse is before the write.
//
// The host here has no burrowee-gateway anywhere — no bundle, no per-user copy —
// so there is nothing the unit could legitimately name.
func TestInstallShRefusesToWriteAUnitItCannotBackWithARootOwnedBinary(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	// Deliberately NOT seedMigrateCapableCLI: an empty host.

	out := runInstallShExpectFail(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	if !strings.Contains(out, "burrowee-gateway") || !strings.Contains(out, binDir(home)) {
		t.Errorf("the refusal does not name the binary and the directory it was missing from:\n%s", out)
	}
	if _, err := os.Stat(coreUnitPath(home)); err == nil {
		t.Errorf("a system unit was written anyway at %s — the refusal came too late to matter", coreUnitPath(home))
	}
}

// TestInstallShConvergesAHostWhoseUnitNamesThePerUserBinDir is the migration.
//
// Hosts already on 0.2.0 carry a unit pointing at ~<installer>/.local/bin
// (devBinDir here — the historical per-user default, deliberately NOT the
// directory this run installs into, so the assertion is about a STALE unit
// being rewritten rather than one that happened to be right). Refusing
// to write NEW bad units does nothing for such a host, because nothing
// rewrites a unit until an install runs. This is that install: `burrowee
// gateway service install` re-runs the kept installer in units-only mode,
// which re-verifies the binaries at $BIN_DIR and rewrites the unit to name
// it. Every update path reaches the same code, so convergence needs no
// ladder rung of its own and repeats idempotently instead of happening once.
func TestInstallShConvergesAHostWhoseUnitNamesThePerUserBinDir(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)

	// A unit shaped like it names some OTHER, unrelated per-user path — not
	// today's $BIN_DIR — so a rewrite is genuinely observable rather than a
	// no-op that happens to already agree.
	stalePath := filepath.Join(home, "some-other-user", ".local", "bin", "burrowee-gateway")
	unit := coreUnitPath(home)
	if err := os.MkdirAll(filepath.Dir(unit), 0o755); err != nil {
		t.Fatal(err)
	}
	// A 0.2.0-shaped unit: root scheme (no UserName / User=, so the slot is
	// free and no consent prompt fires) naming a per-user ExecStart.
	stale := "[Unit]\nDescription=burrowee-gateway\n\n[Service]\nExecStart=" + stalePath + " --no-open\nRestart=always\n"
	if runtime.GOOS == "darwin" {
		stale = "<plist version=\"1.0\"><dict>\n  <key>Label</key><string>com.burrowee.gateway</string>\n" +
			"  <key>ProgramArguments</key><array><string>" + stalePath + "</string><string>--no-open</string></array>\n</dict></plist>\n"
	}
	if err := os.WriteFile(unit, []byte(stale), 0o644); err != nil {
		t.Fatal(err)
	}

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	got := readFile(t, unit)
	if strings.Contains(got, stalePath) {
		t.Errorf("the unit still names the stale per-user binary after a repair run:\n%s", got)
	}
	assertContains(t, got, filepath.Join(binDir(home), "burrowee-gateway"))
}

// TestInstallShUninstallRemovesTheBinaries: leaving root-owned binaries and a
// root-owned installer behind means the next install inherits them without
// ever re-verifying them.
func TestInstallShUninstallRemovesTheBinaries(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)

	runInstallShFrom(t, staging, home, stub)
	if _, err := os.Stat(filepath.Join(binDir(home), "burrowee-gateway")); err != nil {
		t.Fatalf("test is not discriminating — $BIN_DIR was never populated: %v", err)
	}

	runInstallSh(t, home, stub, "BURROWEE_UNINSTALL=1")

	for _, b := range allBins {
		if _, err := os.Stat(filepath.Join(binDir(home), b)); err == nil {
			t.Errorf("%s survived the uninstall", filepath.Join(binDir(home), b))
		}
	}
	if _, err := os.Stat(filepath.Join(binDir(home), "install.sh")); err == nil {
		t.Errorf("the kept installer copy survived the uninstall at %s", binDir(home))
	}
}

// runInstallShFrom runs install.sh with cwd = a staged bundle dir (fresh mode
// resolves its binaries as "./<name>") against a sandbox HOME.
func runInstallShFrom(t *testing.T, bundleDir, home, stubDir string, extraEnv ...string) string {
	t.Helper()
	out, err := runStaged(t, installShPath(t), bundleDir, home, stubDir, extraEnv...)
	if err != nil {
		t.Logf("install.sh output:\n%s", out)
		t.Fatalf("install.sh failed: %v", err)
	}
	return out
}

// fakeRootUID drops an `id` stub that reports uid 0 into the stub dir.
//
// install.sh only asserts ownership when its elevation path genuinely reaches
// uid 0 (have_real_root), which the harness's pass-through sudo never does — so
// the ownership walk is normally skipped here and could be deleted unnoticed.
// This makes the script believe it IS root while every file it places is still
// owned by the test user, which is exactly the state the walk has to catch: a
// $BIN_DIR a non-root user can rewrite.
func fakeRootUID(t *testing.T, stubDir string) {
	t.Helper()
	stub := "#!/bin/sh\nif [ \"$1\" = \"-u\" ]; then echo 0; exit 0; fi\nexec /usr/bin/id \"$@\"\n"
	if err := os.WriteFile(filepath.Join(stubDir, "id"), []byte(stub), 0o755); err != nil {
		t.Fatal(err)
	}
}

// TestInstallShRefusesABinDirItCannotProveIsRootOwned drives the shell
// ownership walk against REAL filesystem state: $BIN_DIR is placed, and it is
// owned by this unprivileged user.
//
// /usr/local is root-owned on a modern macOS and on every Linux, but it is not
// guaranteed to be — a host where a package manager chowned it would otherwise
// get a root-scheme unit pointing into a directory its owner can rewrite.
func TestInstallShRefusesABinDirItCannotProveIsRootOwned(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: the files this test places would really be root-owned, so the refusal is unreachable")
	}
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)
	fakeRootUID(t, stub)

	out := runInstallShExpectFail(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	if !strings.Contains(out, "not root-owned") {
		t.Errorf("the refusal does not say what failed:\n%s", out)
	}
	if _, err := os.Stat(coreUnitPath(home)); err == nil {
		t.Errorf("a system unit was written naming a directory the installer could not prove root-owned: %s", coreUnitPath(home))
	}
}

// TestInstallShPlacesThePrivilegedCLIBeforeRunningTheMigration is about
// ORDERING, which no placement assertion can catch.
//
// migrations/v0_1_to_v0_2.sh runs `elevate "$CLI" migrate`, resolving $CLI from
// $BIN_DIR. If $BIN_DIR were only populated with the units — after the
// migration — then every upgrading host would exec a per-user cli as root
// exactly once, on the console-push path, with no operator present.
// Populating it first is what closes that.
func TestInstallShPlacesThePrivilegedCLIBeforeRunningTheMigration(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLIAtDevBinDir(t, home)
	bundle := t.TempDir()
	script := stageInstaller(t, bundle)
	logPath := filepath.Join(t.TempDir(), "migration.log")
	// The observation has to be made FROM INSIDE the migration. Stat-ing
	// $BIN_DIR after the run proves nothing: render_units populates it too, so
	// a version that placed nothing until the units were written would look
	// identical from the outside.
	stageMigrationRecordingPrivilegedCLI(t, bundle, logPath, binDir(home))

	out, err := runStaged(t, script, home, home, stub, "BURROWEE_UNITS_ONLY=1")
	if err != nil {
		t.Fatalf("install.sh failed: %v\n%s", err, out)
	}
	got := migrationLog(t, logPath)
	if got == "" {
		t.Fatalf("the migration never ran, so this test proves nothing:\n%s", out)
	}
	if !strings.Contains(got, "PRIVILEGED_CLI=present") {
		t.Errorf("the migration ran before the cli existed at $BIN_DIR — it would have shelled to a per-user copy as root; it saw: %q", strings.TrimSpace(got))
	}
}

// stageMigrationRecordingPrivilegedCLI plants a fake migrations/run.sh beside a
// staged installer that records, at the moment it runs, whether the root-owned
// cli is already in place.
func stageMigrationRecordingPrivilegedCLI(t *testing.T, dir, logPath, bin string) {
	t.Helper()
	mig := filepath.Join(dir, "migrations")
	if err := os.MkdirAll(mig, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\n" +
		"_p=absent; [ -x " + shQuote(filepath.Join(bin, "burrowee-gateway-cli")) + " ] && _p=present\n" +
		"echo \"PRIVILEGED_CLI=$_p\" >> " + shQuote(logPath) + "\n" +
		"echo migration-ran\nexit 0\n"
	if err := os.WriteFile(filepath.Join(mig, "run.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}
