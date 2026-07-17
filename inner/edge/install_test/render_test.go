// Package install_test is a Go test harness that runs the edge install.sh in a
// sandbox with stubbed id/systemctl/launchctl. It exercises the ROOT (system)
// branch — the topology the release bootstrap actually deploys — without being
// root, by stubbing `id -u` to 0 and redirecting the system install paths
// (SYS_BIN_DIR / SYSTEMD_UNIT_DIR) into the sandbox.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// edgeBins is the full edge binary set install.sh expects in the archive.
var edgeBins = []string{
	"burrowee",
	"burrowee-edge",
	"burrowee-edge-cli",
	"burrowee-edge-updater",
}

// installShPath resolves inner/edge/install.sh relative to this file.
func installShPath(t *testing.T) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "install.sh"))
	if err != nil {
		t.Fatalf("resolve install.sh: %v", err)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("install.sh not found at %s: %v", p, err)
	}
	return p
}

// stubBin writes an executable stub named name into dir that appends "name $*"
// to $STUB_LOG and exits 0.
func stubBin(t *testing.T, dir, name, body string) {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
		t.Fatalf("write stub %s: %v", name, err)
	}
}

// stubRootEnv builds a stub PATH dir so install.sh takes the Linux ROOT branch in
// a sandbox: id → uid 0 (is_root true), uname -s → Linux (the production edge
// topology; pins the test to the systemd branch regardless of the test host OS),
// and systemctl as a call recorder. install + chmod are real (the sandbox paths
// are writable), so the rendered unit files are inspectable. The systemctl stub
// models `is-enabled`/`is-active` as non-zero (unit not opted in) unless
// STUB_UPDATER_OPTED_IN=1 — so the installer's updater-restart guard only fires
// when the owner previously enabled the auto-updater, matching production.
func stubRootEnv(t *testing.T) string {
	t.Helper()
	stub := t.TempDir()
	stubBin(t, stub, "id", "#!/bin/sh\nif [ \"$1\" = \"-u\" ]; then echo 0; else echo \"id $*\" >> \"$STUB_LOG\"; fi\n")
	stubBin(t, stub, "uname", "#!/bin/sh\nif [ \"$1\" = \"-s\" ]; then echo Linux; else /usr/bin/uname \"$@\"; fi\n")
	stubBin(t, stub, "systemctl", "#!/bin/sh\necho \"systemctl $*\" >> \"$STUB_LOG\"\ncase \"$1\" in is-enabled|is-active) [ \"${STUB_UPDATER_OPTED_IN:-}\" = 1 ] || exit 1 ;; esac\nexit 0\n")
	return stub
}

// seedEdgeBins lays a dummy executable for each edge binary into dir (the install
// cwd; install.sh copies from "./<bin>").
func seedEdgeBins(t *testing.T, dir string) {
	t.Helper()
	for _, b := range edgeBins {
		if err := os.WriteFile(filepath.Join(dir, b), []byte("#!/bin/sh\necho "+b+"\n"), 0o755); err != nil {
			t.Fatalf("seed bin %s: %v", b, err)
		}
	}
}

// readFile reads path, failing the test on error.
func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}

// assertContains asserts s contains every want substring.
func assertContains(t *testing.T, s string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(s, w) {
			t.Errorf("expected content to contain %q\ngot:\n%s", w, s)
		}
	}
}

// runRootInstall runs install.sh as the simulated-root system install in a sandbox:
// system binaries land in sysBinDir, system units in unitDir (both under sandbox).
// Returns (sysBinDir, unitDir, combined output).
func runRootInstall(t *testing.T, home, staging string, extraEnv ...string) (string, string, string) {
	t.Helper()
	stub := stubRootEnv(t)
	sysBinDir := filepath.Join(home, "sysbin")
	unitDir := filepath.Join(home, "systemd-system")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		t.Fatalf("mkdir unitDir: %v", err)
	}

	env := []string{
		"HOME=" + home,
		"PATH=" + stub + ":/usr/bin:/bin",
		"STUB_LOG=" + filepath.Join(home, "stub-calls.log"),
		"SYS_BIN_DIR=" + sysBinDir,
		"SYSTEMD_UNIT_DIR=" + unitDir,
	}
	env = append(env, extraEnv...)

	cmd := exec.Command("sh", installShPath(t))
	cmd.Dir = staging
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Logf("install.sh output:\n%s", out)
		t.Fatalf("install.sh (root branch) failed: %v", err)
	}
	return sysBinDir, unitDir, string(out)
}

// TestEdgeRootInstallWritesUpdaterUnit is the regression guard for the headless
// auto-updater bug: a root install must render the burrowee-edge-updater SYSTEM
// unit (so a pushed update can restart the system serve unit), with HOME=/root and
// WantedBy=multi-user.target mirroring the serve unit — and leave it DISABLED
// (no `systemctl enable`/`start` for the updater; owner opt-in).
func TestEdgeRootInstallWritesUpdaterUnit(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)

	sysBinDir, unitDir, out := runRootInstall(t, home, staging)

	// Both system binaries present.
	for _, b := range edgeBins {
		if _, err := os.Stat(filepath.Join(sysBinDir, b)); err != nil {
			t.Errorf("binary not installed to sys bin dir: %s: %v", b, err)
		}
	}

	servePath := filepath.Join(unitDir, "burrowee-edge.service")
	updaterPath := filepath.Join(unitDir, "burrowee-edge-updater.service")

	if _, err := os.Stat(servePath); err != nil {
		t.Fatalf("serve unit missing: %v", err)
	}
	if _, err := os.Stat(updaterPath); err != nil {
		t.Fatalf("updater unit missing — auto-updater would be headless on a root install: %v", err)
	}

	updater := readFile(t, updaterPath)
	assertContains(t, updater,
		"Description=burrowee edge updater",
		"ExecStart="+sysBinDir+"/burrowee-edge-updater run",
		"Environment=HOME=/root",
		"WantedBy=multi-user.target",
	)

	// DISABLED: the install never enables/starts the updater unit (owner opt-in).
	log := readFile(t, filepath.Join(home, "stub-calls.log"))
	if strings.Contains(log, "enable --now burrowee-edge-updater") ||
		strings.Contains(log, "start burrowee-edge-updater") ||
		strings.Contains(log, "restart burrowee-edge-updater") {
		t.Errorf("updater unit must be left DISABLED; systemctl log enabled/started it:\n%s", log)
	}
	// Sanity: the SERVE unit IS enabled (so the test asserts a meaningful contrast).
	if !strings.Contains(log, "enable --now burrowee-edge") {
		t.Errorf("expected serve unit to be enabled; log:\n%s", log)
	}
	assertContains(t, out, "burrowee-edge-updater.service")
}

// stubDarwinRootEnv builds a stub PATH dir so install.sh takes the macOS ROOT
// branch in a sandbox: id → uid 0 (is_root true), uname -s → Darwin, launchctl
// as a call recorder (launchctl bootstrap must succeed for install.sh to
// proceed), xattr as a no-op.
func stubDarwinRootEnv(t *testing.T) string {
	t.Helper()
	stub := t.TempDir()
	stubBin(t, stub, "id", "#!/bin/sh\nif [ \"$1\" = \"-u\" ]; then echo 0; else echo \"id $*\" >> \"$STUB_LOG\"; fi\n")
	stubBin(t, stub, "uname", "#!/bin/sh\nif [ \"$1\" = \"-s\" ]; then echo Darwin; else /usr/bin/uname \"$@\"; fi\n")
	stubBin(t, stub, "launchctl", "#!/bin/sh\necho \"launchctl $*\" >> \"$STUB_LOG\"\ncase \"$1\" in print) [ \"${STUB_UPDATER_OPTED_IN:-}\" = 1 ] || exit 1 ;; esac\nexit 0\n")
	stubBin(t, stub, "xattr", "#!/bin/sh\nexit 0\n")
	return stub
}

// TestEdgeRootInstallDarwin is the regression guard for the macOS root install:
// COMP_HOME must resolve under root's REAL macOS home (/var/root — never /root,
// which sits on the sealed system volume), so installing the shipped covers/
// cannot abort the script under set -eu before the LaunchDaemon is written; the
// serve plist must pin HOME for the daemon (launchd daemons get no HOME); and
// the opt-in updater plist is rendered but never bootstrapped.
func TestEdgeRootInstallDarwin(t *testing.T) {
	home := t.TempDir()
	rootHome := filepath.Join(home, "var-root") // via the ROOT_HOME test seam
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	// Ship covers/ like every real edge zip does — pre-fix, the unwritable
	// /root COMP_HOME made `mkdir -p "$COMP_HOME/covers"` abort right here.
	if err := os.MkdirAll(filepath.Join(staging, "covers"), 0o755); err != nil {
		t.Fatalf("mkdir covers: %v", err)
	}
	for _, cf := range []string{"admin.html", "default.html"} {
		if err := os.WriteFile(filepath.Join(staging, "covers", cf), []byte("<html></html>"), 0o644); err != nil {
			t.Fatalf("seed cover %s: %v", cf, err)
		}
	}

	stub := stubDarwinRootEnv(t)
	sysBinDir := filepath.Join(home, "sysbin")
	launchdDir := filepath.Join(home, "launch-daemons")
	if err := os.MkdirAll(launchdDir, 0o755); err != nil {
		t.Fatalf("mkdir launchdDir: %v", err)
	}

	cmd := exec.Command("sh", installShPath(t))
	cmd.Dir = staging
	cmd.Env = []string{
		"HOME=" + home,
		"PATH=" + stub + ":/usr/bin:/bin",
		"STUB_LOG=" + filepath.Join(home, "stub-calls.log"),
		"SYS_BIN_DIR=" + sysBinDir,
		"LAUNCHD_PLIST_DIR=" + launchdDir,
		"ROOT_HOME=" + rootHome,
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Logf("install.sh output:\n%s", out)
		t.Fatalf("install.sh (darwin root branch) failed: %v", err)
	}

	// All binaries landed in the system bin dir.
	for _, b := range edgeBins {
		if _, err := os.Stat(filepath.Join(sysBinDir, b)); err != nil {
			t.Errorf("binary not installed to sys bin dir: %s: %v", b, err)
		}
	}
	// Covers landed under root's home — the exact step that aborted pre-fix.
	for _, cf := range []string{"admin.html", "default.html"} {
		if _, err := os.Stat(filepath.Join(rootHome, ".burrowee", "edge", "covers", cf)); err != nil {
			t.Errorf("cover not installed under root home: %s: %v", cf, err)
		}
	}

	// Serve plist: rendered with HOME pinned to root's home (mirrors the
	// systemd unit's Environment=HOME=/root).
	servePlist := filepath.Join(launchdDir, "com.burrowee.edge.plist")
	serve := readFile(t, servePlist)
	assertContains(t, serve,
		"<key>Label</key><string>com.burrowee.edge</string>",
		"<string>"+sysBinDir+"/burrowee-edge</string>",
		"<key>EnvironmentVariables</key><dict><key>HOME</key><string>"+rootHome+"</string></dict>",
	)

	// Updater plist: rendered (parity with the disabled systemd updater unit)…
	updater := readFile(t, filepath.Join(launchdDir, "com.burrowee.edge.updater.plist"))
	assertContains(t, updater,
		"<key>Label</key><string>com.burrowee.edge.updater</string>",
		"<string>"+sysBinDir+"/burrowee-edge-updater</string>",
		"<key>EnvironmentVariables</key><dict><key>HOME</key><string>"+rootHome+"</string></dict>",
	)

	// …but never bootstrapped/started (owner opt-in); the SERVE daemon is. The
	// installer may READ the updater's load state (`launchctl print`) to decide
	// whether a reinstall should advance an already-opted-in updater — that
	// read-only probe is fine; what must NOT happen is bootstrap/enable/kickstart.
	log := readFile(t, filepath.Join(home, "stub-calls.log"))
	if !strings.Contains(log, "bootstrap system "+servePlist) {
		t.Errorf("serve LaunchDaemon was not bootstrapped; launchctl log:\n%s", log)
	}
	for _, forbidden := range []string{
		"bootstrap system " + filepath.Join(launchdDir, "com.burrowee.edge.updater.plist"),
		"enable system/com.burrowee.edge.updater",
		"kickstart -k system/com.burrowee.edge.updater",
	} {
		if strings.Contains(log, forbidden) {
			t.Errorf("updater LaunchDaemon must be left NOT bootstrapped; found %q in launchctl log:\n%s", forbidden, log)
		}
	}
}

// TestEdgeRootUninstallRemovesUpdaterUnit verifies BURROWEE_UNINSTALL removes the
// updater system unit alongside the serve unit on a root install.
func TestEdgeRootUninstallRemovesUpdaterUnit(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)

	sysBinDir, unitDir, _ := runRootInstall(t, home, staging)
	updaterPath := filepath.Join(unitDir, "burrowee-edge-updater.service")
	if _, err := os.Stat(updaterPath); err != nil {
		t.Fatalf("precondition: updater unit should exist after install: %v", err)
	}

	// Uninstall (root branch).
	stub := stubRootEnv(t)
	cmd := exec.Command("sh", installShPath(t))
	cmd.Dir = home
	cmd.Env = []string{
		"HOME=" + home,
		"PATH=" + stub + ":/usr/bin:/bin",
		"STUB_LOG=" + filepath.Join(home, "uninstall-calls.log"),
		"SYS_BIN_DIR=" + sysBinDir,
		"SYSTEMD_UNIT_DIR=" + unitDir,
		"BURROWEE_UNINSTALL=1",
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Logf("uninstall output:\n%s", out)
		t.Fatalf("uninstall failed: %v", err)
	}

	if _, err := os.Stat(updaterPath); err == nil {
		t.Errorf("updater unit still present after uninstall: %s", updaterPath)
	}
	for _, b := range edgeBins {
		if _, err := os.Stat(filepath.Join(sysBinDir, b)); err == nil {
			t.Errorf("binary still present after uninstall: %s", b)
		}
	}
}

// TestEdgeRootInstallRestartsOptedInUpdater is the regression guard for the
// stale-updater deadlock: when the owner has ALREADY opted the auto-updater in,
// a reinstall must restart the updater unit so the daemon advances to the freshly
// installed binary (a stale updater running old code deadlocks future pushes).
// Modeled by STUB_UPDATER_OPTED_IN=1, which makes the systemctl stub report the
// updater enabled/active.
func TestEdgeRootInstallRestartsOptedInUpdater(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)

	_, _, _ = runRootInstall(t, home, staging, "STUB_UPDATER_OPTED_IN=1")

	log := readFile(t, filepath.Join(home, "stub-calls.log"))
	if !strings.Contains(log, "restart burrowee-edge-updater") {
		t.Errorf("opted-in updater must be restarted on reinstall; systemctl log:\n%s", log)
	}
}

// TestEdgeRootInstallDarwinRestartsOptedInUpdater is the macOS counterpart:
// with the updater LaunchDaemon already loaded (owner opt-in, modeled by
// STUB_UPDATER_OPTED_IN=1 so `launchctl print` succeeds), a reinstall must
// kickstart it so the daemon picks up the new binary.
func TestEdgeRootInstallDarwinRestartsOptedInUpdater(t *testing.T) {
	home := t.TempDir()
	rootHome := filepath.Join(home, "var-root")
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	if err := os.MkdirAll(filepath.Join(staging, "covers"), 0o755); err != nil {
		t.Fatalf("mkdir covers: %v", err)
	}
	for _, cf := range []string{"admin.html", "default.html"} {
		if err := os.WriteFile(filepath.Join(staging, "covers", cf), []byte("<html></html>"), 0o644); err != nil {
			t.Fatalf("seed cover %s: %v", cf, err)
		}
	}

	stub := stubDarwinRootEnv(t)
	sysBinDir := filepath.Join(home, "sysbin")
	launchdDir := filepath.Join(home, "launch-daemons")
	if err := os.MkdirAll(launchdDir, 0o755); err != nil {
		t.Fatalf("mkdir launchdDir: %v", err)
	}

	cmd := exec.Command("sh", installShPath(t))
	cmd.Dir = staging
	cmd.Env = []string{
		"HOME=" + home,
		"PATH=" + stub + ":/usr/bin:/bin",
		"STUB_LOG=" + filepath.Join(home, "stub-calls.log"),
		"SYS_BIN_DIR=" + sysBinDir,
		"LAUNCHD_PLIST_DIR=" + launchdDir,
		"ROOT_HOME=" + rootHome,
		"STUB_UPDATER_OPTED_IN=1",
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Logf("install.sh output:\n%s", out)
		t.Fatalf("install.sh (darwin root branch) failed: %v", err)
	}

	log := readFile(t, filepath.Join(home, "stub-calls.log"))
	if !strings.Contains(log, "kickstart -k system/com.burrowee.edge.updater") {
		t.Errorf("opted-in updater LaunchDaemon must be kickstarted on reinstall; launchctl log:\n%s", log)
	}
}
