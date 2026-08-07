// root_exec_test.go — the PRIVILEGED EXECUTION SURFACE ($LIBEXEC_DIR).
//
// 0.2.0 moved the gateway's services to root but left the binaries they name in
// ${PREFIX:-$HOME/.local}/bin, which made every one of those units a standing
// uid-0 grant to the installing user: overwrite the file, wait for a reboot, a
// KeepAlive cycle or a pushed update. These tests are about the tree that
// replaces it and, just as much, about the refusals that keep a unit from ever
// naming anything else.
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

// TestInstallShPlacesTheRootExecedBinariesInThePrivilegedTree checks the
// placement half: every binary a root process execs unattended lands in
// $LIBEXEC_DIR, together with the installer the root updater re-runs.
//
// The absence half is asserted too, and it is not tidiness. burrowee and
// burrowee-register are operator tools that nothing running as root execs;
// copying them in anyway would make the tree's membership rule "everything",
// and a rule that admits everything stops being a rule the next reviewer can
// apply to a new binary.
func TestInstallShPlacesTheRootExecedBinariesInThePrivilegedTree(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	for _, name := range append(rootExecedBins, "install.sh") {
		if _, err := os.Stat(filepath.Join(libexecDir(home), name)); err != nil {
			t.Errorf("%s missing from the privileged tree: %v", name, err)
		}
	}
	for _, name := range []string{"burrowee", "burrowee-register"} {
		if _, err := os.Stat(filepath.Join(libexecDir(home), name)); err == nil {
			t.Errorf("%s was placed in the privileged tree, but nothing execs it as root", name)
		}
	}
}

// TestInstallShKeepsThePerUserBinDirComplete is the unprivileged-flow guard.
// The privileged tree is an ADDITION: $BIN_DIR keeps every binary, because it
// is what PATH resolves, what a developer runs, and the only thing a host that
// cannot reach root ends up with.
func TestInstallShKeepsThePerUserBinDirComplete(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)

	runInstallShFrom(t, staging, home, stub)

	for _, name := range allBins {
		if _, err := os.Stat(filepath.Join(home, ".local", "bin", name)); err != nil {
			t.Errorf("%s missing from the per-user bin dir: %v", name, err)
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

	if !strings.Contains(out, "burrowee-gateway") || !strings.Contains(out, libexecDir(home)) {
		t.Errorf("the refusal does not name the binary and the tree it was missing from:\n%s", out)
	}
	if _, err := os.Stat(coreUnitPath(home)); err == nil {
		t.Errorf("a system unit was written anyway at %s — the refusal came too late to matter", coreUnitPath(home))
	}
}

// TestInstallShConvergesAHostWhoseUnitNamesThePerUserBinDir is the migration.
//
// Hosts already on 0.2.0 carry a unit pointing at ~<installer>/.local/bin, and
// refusing to write NEW bad units does nothing for them — nothing rewrites a
// unit until an install runs. This is that install: `burrowee gateway service
// install` re-runs the kept installer in units-only mode, which copies the
// per-user binaries into the root-owned tree and rewrites the unit to name it.
// Every update path reaches the same code, so convergence needs no ladder rung
// of its own and repeats idempotently instead of happening once.
func TestInstallShConvergesAHostWhoseUnitNamesThePerUserBinDir(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)

	perUserBin := filepath.Join(home, ".local", "bin", "burrowee-gateway")
	unit := coreUnitPath(home)
	if err := os.MkdirAll(filepath.Dir(unit), 0o755); err != nil {
		t.Fatal(err)
	}
	// A 0.2.0-shaped unit: root scheme (no UserName / User=, so the slot is
	// free and no consent prompt fires) naming a per-user ExecStart.
	stale := "[Unit]\nDescription=burrowee-gateway\n\n[Service]\nExecStart=" + perUserBin + " --no-open\nRestart=always\n"
	if runtime.GOOS == "darwin" {
		stale = "<plist version=\"1.0\"><dict>\n  <key>Label</key><string>com.burrowee.gateway</string>\n" +
			"  <key>ProgramArguments</key><array><string>" + perUserBin + "</string><string>--no-open</string></array>\n</dict></plist>\n"
	}
	if err := os.WriteFile(unit, []byte(stale), 0o644); err != nil {
		t.Fatal(err)
	}

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	got := readFile(t, unit)
	if strings.Contains(got, perUserBin) {
		t.Errorf("the unit still names the per-user binary after a repair run:\n%s", got)
	}
	assertContains(t, got, filepath.Join(libexecDir(home), "burrowee-gateway"))
}

// TestInstallShUninstallRemovesThePrivilegedTree: leaving a root-owned tree of
// binaries and a root-owned installer behind means the next install inherits
// them without ever re-verifying them.
func TestInstallShUninstallRemovesThePrivilegedTree(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)

	runInstallShFrom(t, staging, home, stub)
	if _, err := os.Stat(filepath.Join(libexecDir(home), "burrowee-gateway")); err != nil {
		t.Fatalf("test is not discriminating — the privileged tree was never populated: %v", err)
	}

	runInstallSh(t, home, stub, "BURROWEE_UNINSTALL=1")

	if _, err := os.Stat(libexecDir(home)); err == nil {
		t.Errorf("%s survived the uninstall", libexecDir(home))
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
// privileged tree that a non-root user can rewrite.
func fakeRootUID(t *testing.T, stubDir string) {
	t.Helper()
	stub := "#!/bin/sh\nif [ \"$1\" = \"-u\" ]; then echo 0; exit 0; fi\nexec /usr/bin/id \"$@\"\n"
	if err := os.WriteFile(filepath.Join(stubDir, "id"), []byte(stub), 0o755); err != nil {
		t.Fatal(err)
	}
}

// TestInstallShRefusesAPrivilegedTreeItCannotProveIsRootOwned drives the shell
// ownership walk against REAL filesystem state: the tree is placed, and it is
// owned by this unprivileged user.
//
// /usr/local is root-owned on a modern macOS and on every Linux, but it is not
// guaranteed to be — a host where a package manager chowned it would otherwise
// get a root-scheme unit pointing into a tree its owner can rewrite, which is
// the identical vulnerability one directory over.
func TestInstallShRefusesAPrivilegedTreeItCannotProveIsRootOwned(t *testing.T) {
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
		t.Errorf("a system unit was written naming a tree the installer could not prove root-owned: %s", coreUnitPath(home))
	}
}

// TestInstallShPlacesThePrivilegedCLIBeforeRunningTheMigration is about
// ORDERING, which no placement assertion can catch.
//
// migrations/v1_to_v2.sh runs `elevate "$CLI" migrate`, resolving $CLI from the
// privileged tree first and the per-user one otherwise. If the tree were only
// populated with the units — after the migration — then every upgrading host
// would exec a per-user cli as root exactly once, on the console-push path,
// with no operator present. Populating it first is what closes that.
func TestInstallShPlacesThePrivilegedCLIBeforeRunningTheMigration(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)
	bundle := t.TempDir()
	script := stageInstaller(t, bundle)
	logPath := filepath.Join(t.TempDir(), "migration.log")
	// The observation has to be made FROM INSIDE the migration. Stat-ing the
	// tree after the run proves nothing: render_units populates it too, so a
	// version that placed nothing until the units were written would look
	// identical from the outside.
	stageMigrationRecordingPrivilegedCLI(t, bundle, logPath, libexecDir(home))

	out, err := runStaged(t, script, home, home, stub, "BURROWEE_UNITS_ONLY=1")
	if err != nil {
		t.Fatalf("install.sh failed: %v\n%s", err, out)
	}
	got := migrationLog(t, logPath)
	if got == "" {
		t.Fatalf("the migration never ran, so this test proves nothing:\n%s", out)
	}
	if !strings.Contains(got, "PRIVILEGED_CLI=present") {
		t.Errorf("the migration ran before the privileged cli existed — it would have shelled to the per-user copy as root; it saw: %q", strings.TrimSpace(got))
	}
}

// stageMigrationRecordingPrivilegedCLI plants a fake migrations/run.sh beside a
// staged installer that records, at the moment it runs, whether the root-owned
// cli is already in place.
func stageMigrationRecordingPrivilegedCLI(t *testing.T, dir, logPath, libexec string) {
	t.Helper()
	mig := filepath.Join(dir, "migrations")
	if err := os.MkdirAll(mig, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\n" +
		"_p=absent; [ -x " + shQuote(filepath.Join(libexec, "burrowee-gateway-cli")) + " ] && _p=present\n" +
		"echo \"PRIVILEGED_CLI=$_p\" >> " + shQuote(logPath) + "\n" +
		"echo migration-ran\nexit 0\n"
	if err := os.WriteFile(filepath.Join(mig, "run.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}
