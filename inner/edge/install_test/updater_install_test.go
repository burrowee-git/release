// updater_install_test.go — inner/edge/updater.install.sh: the narrow,
// UPDATER-ONLY installer. It exists because the updater is the only
// automatic delivery channel on a node and has no path back to itself: a
// service push updates the serve binary, never the updater, and the
// updater's own binary + unit are otherwise placed only by the full
// install.sh (this file's sibling suite).
//
// What is asserted here, mirroring migrations_test.go's own scope note, is
// the WIRING — the binary lands, the unit is written, the shared ladder runs
// unconditionally and this script acts on its exit code rather than merely
// observing it, the service is started — and the ENROLLMENT PROMISE: nothing
// under the component home is ever touched. It is NOT adopt_updater_unit.sh's
// own convergence logic, which has its own suite
// (tools/adopt_updater_unit.test.sh); TestUpdaterInstallConvergesLegacyUpdaterToTheSystemUnit
// below drives the real rung end-to-end exactly once, to prove the WIRING
// reaches a convergence a caller can observe — not to re-litigate that
// rung's own preconditions.
//
// EVERY PATH HERE IS A FIXTURE TREE under t.TempDir(), same discipline as
// migrations_test.go and render_test.go.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// updaterInstallShPath resolves inner/edge/updater.install.sh relative to
// this file.
func updaterInstallShPath(t *testing.T) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "updater.install.sh"))
	if err != nil {
		t.Fatalf("resolve updater.install.sh: %v", err)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("updater.install.sh not found at %s: %v", p, err)
	}
	return p
}

// stagedUpdaterInstaller copies updater.install.sh INTO dir and returns the
// copy's path. It matters that the script runs from inside the bundle, same
// reason as stagedInstaller (render_test.go): it resolves migrations/
// relative to its OWN path.
func stagedUpdaterInstaller(t *testing.T, dir string) string {
	t.Helper()
	body, err := os.ReadFile(updaterInstallShPath(t))
	if err != nil {
		t.Fatalf("read updater.install.sh: %v", err)
	}
	p := filepath.Join(dir, "updater.install.sh")
	if err := os.WriteFile(p, body, 0o755); err != nil {
		t.Fatalf("stage updater.install.sh: %v", err)
	}
	return p
}

// seedUpdaterBin lays a dummy updater executable into dir (the install cwd;
// updater.install.sh copies from "./burrowee-edge-updater"). Stamped the same
// way seedEdgeBins stamps its binaries, for parity even though this script's
// own logic does not read it.
func seedUpdaterBin(t *testing.T, dir string) {
	t.Helper()
	body := "#!/bin/sh\n# github.com/burrowee-git/edge/cmd/burrowee-edge-updater\necho burrowee-edge-updater\n"
	if err := os.WriteFile(filepath.Join(dir, "burrowee-edge-updater"), []byte(body), 0o755); err != nil {
		t.Fatalf("seed updater bin: %v", err)
	}
}

// stageUpdaterMigrations lays rungScript (rungBody) beside the shared ladder
// staged by stageMigrations, and points migrations/updater-ledger at it
// alone — a minimal, synthetic ladder used ONLY to pin how THIS installer
// reacts to the shared runner's exit codes (0/2/3), independent of which real
// rung eventually ships in migrations/updater-ledger.
func stageUpdaterMigrations(t *testing.T, staging, rungScript, rungBody string) string {
	t.Helper()
	dst := stageMigrations(t, staging)
	if err := os.WriteFile(filepath.Join(dst, rungScript), []byte(rungBody), 0o755); err != nil {
		t.Fatalf("stage %s: %v", rungScript, err)
	}
	if err := os.WriteFile(filepath.Join(dst, "updater-ledger"), []byte("0.2.0 "+rungScript+"\n"), 0o644); err != nil {
		t.Fatalf("write updater-ledger: %v", err)
	}
	return dst
}

// writeRealUpdaterLedger points the shared migrations dir's updater-ledger at
// the REAL convergence rung, adopt_updater_unit.sh, exactly as the shipped
// kit's migrations/updater-ledger will.
func writeRealUpdaterLedger(t *testing.T, migDir string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(migDir, "updater-ledger"), []byte("0.2.0 adopt_updater_unit.sh\n"), 0o644); err != nil {
		t.Fatalf("write updater-ledger: %v", err)
	}
}

// updaterFixture is one sandboxed host for updater.install.sh: the system
// paths it writes to, redirected into a temp tree, plus a CANARY standing in
// for the component home install.sh resolves as COMP_HOME
// (/usr/local/etc/burrowee/edge) — updater.install.sh must never so much as
// look at it. Nothing here resolves outside t.TempDir().
type updaterFixture struct {
	home        string
	staging     string
	sysBinDir   string
	unitDir     string // SYSTEMD_UNIT_DIR
	launchdDir  string // LAUNCHD_PLIST_DIR
	stubLog     string
	compHomeDir string // fixture stand-in for SYS_CONFIG_ROOT/edge (the config home)
	canaryPath  string
	canaryBody  []byte
	// dataHomeDir is the SECOND protected path the header names:
	// SYS_DATA_ROOT/edge (COMP_DATA in install.sh's own terms) —
	// /usr/local/var/burrowee/edge in production. This is the exact
	// directory a log-path/ensure_system_log_dir-shaped regression would
	// create and chmod (see gateway's own updater.install.sh header for why
	// that omission is deliberate); it gets the SAME before/after canary
	// treatment as compHomeDir, not a lesser one.
	dataHomeDir    string // fixture stand-in for SYS_DATA_ROOT/edge (the data home)
	dataCanaryPath string
	dataCanaryBody []byte
	// userHomeDir is the THIRD path the header names: $HOME/.burrowee/edge
	// (GW_HOME in install.sh's own terms) — lower risk (nothing in a
	// system-only script reads $HOME except via `id -u`), included anyway
	// since the helper makes it free.
	userHomeDir        string
	userHomeCanaryPath string
	userHomeCanaryBody []byte
}

// newUpdaterFixture lays out the sandbox, seeds the updater binary, and
// writes the canary BEFORE the installer ever runs — so assertions after the
// run have a known-good "before" to compare against.
func newUpdaterFixture(t *testing.T) *updaterFixture {
	t.Helper()
	home := t.TempDir()
	staging := t.TempDir()
	seedUpdaterBin(t, staging)

	f := &updaterFixture{
		home:       home,
		staging:    staging,
		sysBinDir:  filepath.Join(home, "sysbin"),
		unitDir:    filepath.Join(home, "systemd-system"),
		launchdDir: filepath.Join(home, "launch-daemons"),
		stubLog:    filepath.Join(home, "stub-calls.log"),
	}
	f.compHomeDir = filepath.Join(home, "sys-etc", "burrowee", "edge")
	f.dataHomeDir = filepath.Join(home, "sys-var", "burrowee", "edge")
	f.userHomeDir = filepath.Join(home, ".burrowee", "edge")
	for _, d := range []string{f.compHomeDir, f.dataHomeDir, f.userHomeDir, f.unitDir, f.launchdDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", d, err)
		}
	}
	f.canaryPath = filepath.Join(f.compHomeDir, "identity.canary")
	f.canaryBody = []byte("do-not-touch: this is the component home; updater.install.sh must never write here\n")
	if err := os.WriteFile(f.canaryPath, f.canaryBody, 0o644); err != nil {
		t.Fatalf("write canary: %v", err)
	}
	f.dataCanaryPath = filepath.Join(f.dataHomeDir, "identity.canary")
	f.dataCanaryBody = []byte("do-not-touch: this is the component DATA home; updater.install.sh must never write here\n")
	if err := os.WriteFile(f.dataCanaryPath, f.dataCanaryBody, 0o644); err != nil {
		t.Fatalf("write data canary: %v", err)
	}
	f.userHomeCanaryPath = filepath.Join(f.userHomeDir, "identity.canary")
	f.userHomeCanaryBody = []byte("do-not-touch: this is the per-user component home; updater.install.sh must never write here\n")
	if err := os.WriteFile(f.userHomeCanaryPath, f.userHomeCanaryBody, 0o644); err != nil {
		t.Fatalf("write user-home canary: %v", err)
	}
	return f
}

// env is the environment every run in this file uses: sandboxed system paths
// plus the (today unread by the script, kept so a future regression that
// starts reading it is still caught) component-home seam.
func (f *updaterFixture) env(stub string, extra ...string) []string {
	e := []string{
		"HOME=" + f.home,
		"PATH=" + stub + ":/usr/bin:/bin",
		"STUB_LOG=" + f.stubLog,
		"SYS_BIN_DIR=" + f.sysBinDir,
		"BURROWEE_LEGACY_BIN_DIR=" + filepath.Join(f.home, "usr-local-bin"),
		"SYSTEMD_UNIT_DIR=" + f.unitDir,
		"LAUNCHD_PLIST_DIR=" + f.launchdDir,
		"SYS_CONFIG_ROOT=" + filepath.Dir(f.compHomeDir),
		"SYS_DATA_ROOT=" + filepath.Dir(f.dataHomeDir),
	}
	return append(e, extra...)
}

func (f *updaterFixture) run(t *testing.T, stub string, extra ...string) (string, error) {
	t.Helper()
	cmd := exec.Command("sh", stagedUpdaterInstaller(t, f.staging))
	cmd.Dir = f.staging
	cmd.Env = f.env(stub, extra...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// assertPlacedAndStarted is the shared shape of "the updater landed, the
// unit was written, the service was asked to start" every scenario checks.
func (f *updaterFixture) assertPlacedAndStarted(t *testing.T, out, unitPath string) {
	t.Helper()
	if _, err := os.Stat(filepath.Join(f.sysBinDir, "burrowee-edge-updater")); err != nil {
		t.Errorf("updater binary not placed: %v\noutput:\n%s", err, out)
	}
	if _, err := os.Stat(unitPath); err != nil {
		t.Errorf("updater unit not written at %s: %v\noutput:\n%s", unitPath, err, out)
	}
	log := readFile(t, f.stubLog)
	if !strings.Contains(log, "start") {
		t.Errorf("service was never asked to start; supervisor log:\n%s", log)
	}
}

// assertDirUntouched is the shared shape of a protected-path check: the
// canary's content must be byte-identical to what was written before the
// run, and it must be the ONLY file under dir — both facts read off the
// FILESYSTEM, never off exit status. Used for BOTH protected paths the
// header names (config home and data home) so neither gets a lesser check
// than the other.
func assertDirUntouched(t *testing.T, label, dir, canaryPath string, canaryBody []byte) {
	t.Helper()
	after, err := os.ReadFile(canaryPath)
	if err != nil {
		t.Fatalf("%s canary missing after run: %v", label, err)
	}
	if string(after) != string(canaryBody) {
		t.Errorf("%s canary changed — updater.install.sh touched %s.\nbefore:\n%s\nafter:\n%s", label, dir, canaryBody, after)
	}
	// Count EVERY entry under dir except dir itself — files AND
	// directories. A bare subdirectory with nothing inside it (e.g. an
	// empty "logs" dir a log-path regression would mkdir -p, with no file
	// written into it yet) is still a write to this tree and must fail
	// this check exactly as a stray file would — counting non-dir entries
	// only would let that mutation through uncaught.
	var count int
	if err := filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if p == dir {
			return nil
		}
		count++
		return nil
	}); err != nil {
		t.Fatalf("walk %s: %v", dir, err)
	}
	if count != 1 {
		t.Errorf("%s has %d entries after the run (files+dirs), want 1 (only the canary) — updater.install.sh wrote something there", dir, count)
	}
}

// assertEnrollmentPromise is THE canary check the header promises, covering
// all three protected paths it names: the config home (SYS_CONFIG_ROOT/edge),
// the data home (SYS_DATA_ROOT/edge), and the per-user home
// ($HOME/.burrowee/edge). The data home is the exact directory a
// log-path/ensure_system_log_dir-shaped regression would create and chmod —
// omitting it from this check would leave that invariant with no regression
// protection at all.
func (f *updaterFixture) assertEnrollmentPromise(t *testing.T) {
	t.Helper()
	assertDirUntouched(t, "config home", f.compHomeDir, f.canaryPath, f.canaryBody)
	assertDirUntouched(t, "data home", f.dataHomeDir, f.dataCanaryPath, f.dataCanaryBody)
	assertDirUntouched(t, "per-user home", f.userHomeDir, f.userHomeCanaryPath, f.userHomeCanaryBody)
}

func (f *updaterFixture) assertServeBinAbsent(t *testing.T) {
	t.Helper()
	if _, err := os.Stat(filepath.Join(f.sysBinDir, "burrowee-edge")); err == nil {
		t.Errorf("burrowee-edge (the SERVE binary) was placed — updater.install.sh must place ONLY the updater")
	}
}

// TestUpdaterInstallPlacesUnitAndStartsWithoutTouchingComponentHome is the
// headline scenario (task-1-brief Step 2/5): no migrations/ shipped at all
// (the simplest bundle shape a kit can have), so the ladder step is a
// structural no-op — this pins the install itself, independent of the
// ladder, and the enrollment promise together with it.
func TestUpdaterInstallPlacesUnitAndStartsWithoutTouchingComponentHome(t *testing.T) {
	f := newUpdaterFixture(t)

	out, err := f.run(t, stubRootEnv(t))
	if err != nil {
		t.Fatalf("updater.install.sh failed: %v\noutput:\n%s", err, out)
	}

	unitPath := filepath.Join(f.unitDir, "burrowee-edge-updater.service")
	f.assertPlacedAndStarted(t, out, unitPath)
	f.assertEnrollmentPromise(t)
	f.assertServeBinAbsent(t)
}

// TestUpdaterInstallRunsTheRealLadderAndStillInstalls exercises the REAL
// shared ladder with the REAL convergence rung (migrations/updater-ledger =
// "0.2.0 adopt_updater_unit.sh"), under the ordinary generic systemctl stub
// every other Linux-shaped test in this package uses (render_test.go's
// stubRootEnv) — which answers "unknown" to a --user systemd query, exactly
// as a real host where this process cannot reach a user manager does. That is
// itself a legitimate, common real-world outcome (see adopt_updater_unit.sh's
// own "LINUX SCOPE" reasoning): the rung declines gracefully, and the install
// still completes end to end.
func TestUpdaterInstallRunsTheRealLadderAndStillInstalls(t *testing.T) {
	f := newUpdaterFixture(t)
	migDir := stageMigrations(t, f.staging)
	writeRealUpdaterLedger(t, migDir)

	out, err := f.run(t, stubRootEnv(t))
	if err != nil {
		t.Fatalf("updater.install.sh failed: %v\noutput:\n%s", err, out)
	}

	assertContains(t, out, "migrate: ")
	unitPath := filepath.Join(f.unitDir, "burrowee-edge-updater.service")
	f.assertPlacedAndStarted(t, out, unitPath)
}

// alwaysDefersRung is a synthetic migration used ONLY to pin how
// updater.install.sh reacts to a DEFERRED (exit 3) ladder — not to exercise
// adopt_updater_unit.sh's own "cannot reach root" precondition for a real
// exit 3, which requires a non-root invocation this package's sandboxes do
// not model (every other scenario here runs as simulated root, like the rest
// of the suite). This is the same "test the wiring, not the rung" split
// migrations_test.go's header describes.
const alwaysDefersRung = "#!/bin/sh\nif [ \"${1:-}\" = --applies ]; then exit 0; fi\nexit 3\n"

// TestUpdaterInstallDeferredLadderDoesNotAbortInstall is task-1-brief Step 6:
// a rung returning 3 must still complete the install and start the service —
// 3 means the rung ran nothing and stopped nothing.
func TestUpdaterInstallDeferredLadderDoesNotAbortInstall(t *testing.T) {
	f := newUpdaterFixture(t)
	stageUpdaterMigrations(t, f.staging, "always_defers.sh", alwaysDefersRung)

	out, err := f.run(t, stubRootEnv(t))
	if err != nil {
		t.Fatalf("a deferred (exit 3) rung must not abort the install: %v\noutput:\n%s", err, out)
	}

	unitPath := filepath.Join(f.unitDir, "burrowee-edge-updater.service")
	f.assertPlacedAndStarted(t, out, unitPath)
}

// convergenceDarwinStub builds a PATH dir for the legacy-convergence
// scenario: id -> uid 0, uname -s -> Darwin, and a STATEFUL launchctl close
// enough to a real supervisor for adopt_updater_unit.sh's own gates to clear:
//
//   - `print gui/<uid>/org.burrowee.edge-updater` succeeds (legacy PRESENT)
//     until `bootout` targets that same gui/ job, after which it fails
//     (legacy GONE) — legacyGoneMarker is that state.
//   - `print system/com.burrowee.edge.updater` fails until `bootstrap`
//     writes sysLoadedMarker. Required: adopt_updater_unit.sh never boots the
//     legacy agent out until it can positively confirm the system unit it
//     just wrote is loaded (its header, "IT NEVER BOOTS OUT BLIND") — a
//     stub that always answered "loaded" would let the rung skip straight to
//     bootout without that confirmation ever being real, which is not the
//     path a live host takes.
//
// legacyGoneMarker doubles as this suite's answer to the brief's undefined
// count_loaded helper (see task-1-brief's decision #1): a filesystem fact
// recording whether the legacy gui-domain job is still there, kept by the
// SAME stub state adopt_updater_unit.sh's own verify-before-bootout gate
// already requires — not a second, invented bookkeeping mechanism.
func convergenceDarwinStub(t *testing.T, legacyGoneMarker, sysLoadedMarker string) string {
	t.Helper()
	stub := t.TempDir()
	stubBin(t, stub, "id", "#!/bin/sh\nif [ \"$1\" = \"-u\" ]; then echo 0; else echo \"id $*\" >> \"$STUB_LOG\"; fi\n")
	stubBin(t, stub, "uname", "#!/bin/sh\nif [ \"$1\" = \"-s\" ]; then echo Darwin; else /usr/bin/uname \"$@\"; fi\n")
	body := "#!/bin/sh\n" +
		"echo \"launchctl $*\" >> \"$STUB_LOG\"\n" +
		"case \"$1\" in\n" +
		"print)\n" +
		"    case \"$2\" in\n" +
		"    gui/*) [ -f '" + legacyGoneMarker + "' ] && exit 1; exit 0 ;;\n" +
		"    system/*) [ -f '" + sysLoadedMarker + "' ] && exit 0; exit 1 ;;\n" +
		"    esac\n" +
		"    ;;\n" +
		"bootstrap)\n" +
		"    : > '" + sysLoadedMarker + "'\n" +
		"    ;;\n" +
		"bootout)\n" +
		"    case \"$2\" in\n" +
		"    gui/*) : > '" + legacyGoneMarker + "' ;;\n" +
		"    esac\n" +
		"    ;;\n" +
		"esac\n" +
		"exit 0\n"
	stubBin(t, stub, "launchctl", body)
	stubBin(t, stub, "xattr", "#!/bin/sh\nexit 0\n")
	return stub
}

// TestUpdaterInstallConvergesLegacyUpdaterToTheSystemUnit is task-1-brief
// Step 7, the spec's sharpest test: a host with a legacy per-user updater
// agent must end with ONE updater, not two. Runs the REAL adopt_updater_unit.sh
// (see the package-level comment for why this one scenario earns that, unlike
// the deferred-ladder test above).
func TestUpdaterInstallConvergesLegacyUpdaterToTheSystemUnit(t *testing.T) {
	f := newUpdaterFixture(t)
	migDir := stageMigrations(t, f.staging)
	writeRealUpdaterLedger(t, migDir)

	legacyGoneMarker := filepath.Join(f.home, "legacy-gone.marker")
	sysLoadedMarker := filepath.Join(f.home, "sys-loaded.marker")
	stub := convergenceDarwinStub(t, legacyGoneMarker, sysLoadedMarker)

	out, err := f.run(t, stub)
	if err != nil {
		t.Fatalf("updater.install.sh failed converging the legacy updater: %v\noutput:\n%s", err, out)
	}

	unitPath := filepath.Join(f.launchdDir, "com.burrowee.edge.updater.plist")
	f.assertPlacedAndStarted(t, out, unitPath)

	log := readFile(t, f.stubLog)
	if !strings.Contains(log, "bootout") {
		t.Errorf("legacy per-user updater was never booted out; launchctl log:\n%s", log)
	}
	if !strings.Contains(log, "system/com.burrowee.edge.updater") {
		t.Errorf("system updater unit was never addressed; launchctl log:\n%s", log)
	}
	if _, statErr := os.Stat(legacyGoneMarker); statErr != nil {
		t.Errorf("legacy per-user updater agent is still loaded after the run — TWO updaters remain: %v", statErr)
	}
}
