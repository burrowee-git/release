// operator_home_test.go — A ROOT-RUN INSTALL WRITES NOTHING UNDER A USER'S HOME.
//
// The defect, observed on a workstation 2026-09-05: `curl … | sudo sh` left
// `drwxr-xr-x root staff ~/.burrowee` holding `guard.sh install.sh migrations/`,
// after which the cli installer could not create `~/.burrowee/cli`, `burrowee
// cli bootstrap` failed, and `doctor --fix` had nothing it could repair. The
// cause was keep_installer_copy: root, with the operator's preserved $HOME,
// mkdir -p'ing and copying into it unconditionally in every mode. The version
// anchor was a second write to the same tree.
//
// Neither of the two things elevation exists for (writing a system config file,
// installing a system daemon) is a file in somebody's home, so what these tests
// pin is not "the copy moved" but "the copy is gone and the elevated write
// landed in the machine-owned tree instead".
//
// WHY $SUDO_USER RATHER THAN A REAL ELEVATED RUN. The suite cannot run as root
// — that is the point of every stub in this package — so it drives the branch
// the ELEVATED run takes: $SUDO_USER names a seamed account (getent/dscl stubs,
// gatewayPasswdStubs) whose home is NOT the sandbox $HOME. That is the exact
// shape of `curl … | sudo sh`, where $HOME is the invoking operator's on macOS
// and root's on Linux and NEITHER is a safe place for an installer to write.
// An implementation reading $HOME resolves the sandbox home; one reading
// operator_home resolves the seamed account's. Both are asserted clean, so a
// regression in either direction reddens these tests.
package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// operatorSandbox stages the `curl … | sudo sh` shape: a stub PATH whose passwd
// database answers for exactly one account, that account's home as a directory
// the test can watch, and the SUDO_USER entry install.sh resolves it through.
//
// The returned home is a sibling of the sandbox $HOME, not a child of it: every
// other seam in this package (the system root, the unit dirs, the legacy exec
// root) hangs off $HOME, so an assertion about "the operator's home" would
// otherwise be an assertion about half the sandbox.
func operatorSandbox(t *testing.T, home, stub string) string {
	t.Helper()
	operatorHome := filepath.Join(t.TempDir(), "operator")
	if err := os.MkdirAll(operatorHome, 0o700); err != nil {
		t.Fatal(err)
	}
	gatewayPasswdStubs(t, stub, "gw-operator", operatorHome, "/bin/zsh")
	return operatorHome
}

// treeSnapshot lists every path under dir, relative to it. Absent is the empty
// list, never a failure: "the installer created the tree" is one of the things
// being asserted about.
func treeSnapshot(t *testing.T, dir string) []string {
	t.Helper()
	var out []string
	err := filepath.Walk(dir, func(p string, _ os.FileInfo, err error) error {
		if err != nil {
			if os.IsNotExist(err) {
				return nil
			}
			return err
		}
		rel, relErr := filepath.Rel(dir, p)
		if relErr != nil {
			return relErr
		}
		if rel != "." {
			out = append(out, rel)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", dir, err)
	}
	return out
}

// assertOperatorHomeUntouched is the assertion every mode owes, spelled once.
// It is deliberately about ~/.burrowee rather than the whole of $HOME, because
// this suite's own seams (the sandboxed system root, the unit dirs) live under
// $HOME by construction — see the sysConfigDir/binDir comments in render_test.go.
func assertOperatorHomeUntouched(t *testing.T, home string) {
	t.Helper()
	p := filepath.Join(home, ".burrowee")
	if _, err := os.Stat(p); err == nil {
		t.Errorf("the installer created %s — a root-run install must leave the operator's home alone; entries: %v", p, treeSnapshot(t, p))
	} else if !os.IsNotExist(err) {
		t.Fatalf("stat %s: %v", p, err)
	}
}

// TestFreshInstallUnderSudoWritesNothingUnderTheOperatorHome is acceptance
// criterion 1, in the shape the defect was reported in: a fresh install with an
// operator $HOME preserved across the elevation creates nothing under it.
//
// BOTH homes are asserted, because the two implementations differ in which one
// they would have written to and either is wrong. The operator's home is
// snapshotted before and after rather than only checked for ~/.burrowee: a
// future installer that decided to leave a receipt, a log or a lockfile under a
// different name in there would still be a root process writing a human's tree.
//
// Mutation that reddens it: put keep_installer_copy back and call it.
func TestFreshInstallUnderSudoWritesNothingUnderTheOperatorHome(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	operatorHome := operatorSandbox(t, home, stub)
	staging := t.TempDir()
	seedDummyBins(t, staging)

	before := treeSnapshot(t, operatorHome)

	out, err := runStaged(t, stageInstaller(t, staging), staging, home, stub, "SUDO_USER=gw-operator")
	if err != nil {
		t.Fatalf("fresh install failed: %v\n%s", err, out)
	}

	if after := treeSnapshot(t, operatorHome); len(after) != len(before) {
		t.Errorf("the install wrote into the operator's home %s: before %v, after %v", operatorHome, before, after)
	}
	assertOperatorHomeUntouched(t, home)
	assertOperatorHomeUntouched(t, operatorHome)
}

// TestUnitsOnlyUnderSudoWritesNothingUnderTheOperatorHome is the same criterion
// for `burrowee gateway service install` / `doctor --fix`, which is the entry
// point an operator repairing a host actually types — and the one that used to
// make the per-user copy on every single invocation.
func TestUnitsOnlyUnderSudoWritesNothingUnderTheOperatorHome(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	operatorHome := operatorSandbox(t, home, stub)
	seedMigrateCapableCLI(t, home)

	before := treeSnapshot(t, operatorHome)

	runInstallSh(t, home, stub,
		"BURROWEE_UNITS_ONLY=1",
		"SUDO_USER=gw-operator",
		"BURROWEE_VERSION=gateway/v0.3.0.2026.09.05.abcdef12",
	)

	if after := treeSnapshot(t, operatorHome); len(after) != len(before) {
		t.Errorf("units-only wrote into the operator's home %s: before %v, after %v", operatorHome, before, after)
	}
	assertOperatorHomeUntouched(t, home)
	assertOperatorHomeUntouched(t, operatorHome)
}

// TestTheLadderAnchorLivesInTheSystemConfigRoot is acceptance criterion 2.
//
// The anchor used to be written at $GW_HOME/.installed-version, which was wrong
// twice: it was a root write into a human's home, AND it was a file nothing read
// — the gateway is a `system`-scheme component, so migrations/run.sh resolves
// its anchor to $SYS_CONFIG_ROOT/<comp>/.installed-version. The writer and the
// reader named different files, which is why hosts reached the ladder through
// the --applies fallback the runner's own header calls exceptional.
//
// The $BIN_DIR anchor is the ROOT UPDATER's and is asserted alongside, because
// one writer serves both and a change that moved one must not silently drop the
// other (core's local-update path reads <exec dir>/.installed-version).
//
// Mutation that reddens it: point record_installed_version back at $GW_HOME.
func TestTheLadderAnchorLivesInTheSystemConfigRoot(t *testing.T) {
	const version = "v0.3.0.2026.09.05.abcdef12"

	home := t.TempDir()
	stub := stubInitSystem(t)
	operatorHome := operatorSandbox(t, home, stub)
	seedMigrateCapableCLI(t, home)

	runInstallSh(t, home, stub,
		"BURROWEE_UNITS_ONLY=1",
		"SUDO_USER=gw-operator",
		"BURROWEE_VERSION=gateway/"+version,
	)

	// The ladder's anchor, where migrations/run.sh reads it.
	if got := installedVersion(t, home); got != version {
		t.Errorf("ladder anchor at %s = %q, want %q", ladderAnchorPath(home), got, version)
	}
	// The root updater's, where core's local-update path reads it.
	b, err := os.ReadFile(filepath.Join(binDir(home), ".installed-version"))
	if err != nil {
		t.Fatalf("no root-updater anchor at %s: %v", filepath.Join(binDir(home), ".installed-version"), err)
	}
	if got := strings.TrimSpace(string(b)); got != version {
		t.Errorf("root-updater anchor = %q, want %q", got, version)
	}
	// And neither home holds one.
	for _, h := range []string{home, operatorHome} {
		if _, err := os.Stat(filepath.Join(h, ".burrowee", "gateway", ".installed-version")); err == nil {
			t.Errorf("the version anchor was written into a home tree: %s", filepath.Join(h, ".burrowee", "gateway", ".installed-version"))
		}
	}
}

// TestTheMigrationRunnerIsHandedTheOperatorsLegacyTree is acceptance criterion
// 3 — legacy 0.2 hosts still migrate — and it is the reason $GW_HOME survives
// at all: the 0.2→0.3 rung copies the host's identity OUT of that tree, so the
// installer has to hand it the right one.
//
// $HOME is the wrong one under elevation, and wrong in a way that reports
// success: with no identity to find, the rung declines and the install ends
// clean while the node's enrolment is left behind. Under `sudo` on Linux $HOME
// is root's outright; under `sudo` on macOS it is the operator's only because
// the platform preserves it, which is not a property to build a migration on.
//
// Mutation that reddens it: spell GW_HOME from $HOME instead of $OPERATOR_HOME.
func TestTheMigrationRunnerIsHandedTheOperatorsLegacyTree(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	operatorHome := operatorSandbox(t, home, stub)

	// A pre-0.2.0 host: the operator's per-user tree holds the enrolled
	// identity, and $HOME's does not exist at all.
	legacy := filepath.Join(operatorHome, ".burrowee", "gateway")
	if err := os.MkdirAll(filepath.Join(legacy, "identity"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacy, "identity", "relay_ed.key"), []byte("key"), 0o600); err != nil {
		t.Fatal(err)
	}

	staging := t.TempDir()
	seedDummyBins(t, staging)
	// The pre-flight probe now sees a prior install, so the staged cli has to
	// answer `migrate --help` or assert_can_migrate refuses before any write.
	if err := os.WriteFile(filepath.Join(staging, "burrowee-gateway-cli"), []byte(cliWithMigrate), 0o755); err != nil {
		t.Fatal(err)
	}
	logPath := filepath.Join(t.TempDir(), "migration.log")
	script := stageInstaller(t, staging)
	stageMigration(t, staging, logPath, 0)

	out, err := runStaged(t, script, staging, home, stub, "SUDO_USER=gw-operator")
	if err != nil {
		t.Fatalf("fresh install failed: %v\n%s", err, out)
	}

	log := migrationLog(t, logPath)
	if log == "" {
		t.Fatal("the migration never ran — this test is not exercising the hand-off")
	}
	assertContains(t, log, "GW_HOME="+legacy)
	if strings.Contains(log, "GW_HOME="+filepath.Join(home, ".burrowee", "gateway")) {
		t.Errorf("the runner was handed $HOME's tree, which under sudo is not the enrolled operator's:\n%s", log)
	}
	// The rung's own evidence — the tree it adopts from — is still there, and
	// the installer added nothing of its own to it.
	if _, statErr := os.Stat(filepath.Join(legacy, "identity", "relay_ed.key")); statErr != nil {
		t.Errorf("the legacy identity was disturbed: %v", statErr)
	}
	if _, statErr := os.Stat(filepath.Join(legacy, "install.sh")); statErr == nil {
		t.Errorf("the installer copied itself into the operator's legacy tree: %s", filepath.Join(legacy, "install.sh"))
	}
	assertOperatorHomeUntouched(t, home)
}

// TestTheFirstRunProbeReadsTheOperatorsLegacyTree: the "is this host already
// set up" probe is the other read of the per-user tree, and it must follow the
// same account. A 0.2-enrolled host re-prompted for a setup blob is how a
// second enrolment gets pasted onto a node that already had one.
//
// Mutation that reddens it: spell COMP_HOME from $HOME instead of $OPERATOR_HOME.
func TestTheFirstRunProbeReadsTheOperatorsLegacyTree(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	operatorHome := operatorSandbox(t, home, stub)

	legacy := filepath.Join(operatorHome, ".burrowee", "gateway")
	if err := os.MkdirAll(legacy, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacy, "gateway.db"), []byte("store"), 0o600); err != nil {
		t.Fatal(err)
	}

	staging := t.TempDir()
	seedDummyBins(t, staging)
	if err := os.WriteFile(filepath.Join(staging, "burrowee-gateway-cli"), []byte(cliWithMigrate), 0o755); err != nil {
		t.Fatal(err)
	}

	out, err := runStaged(t, stageInstaller(t, staging), staging, home, stub, "SUDO_USER=gw-operator")
	if err != nil {
		t.Fatalf("fresh install failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "already set up") {
		t.Errorf("an enrolled 0.2 host was not recognised, so it would be re-prompted for a setup blob:\n%s", out)
	}
}
