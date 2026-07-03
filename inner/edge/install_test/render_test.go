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
// are writable), so the rendered unit files are inspectable.
func stubRootEnv(t *testing.T) string {
	t.Helper()
	stub := t.TempDir()
	stubBin(t, stub, "id", "#!/bin/sh\nif [ \"$1\" = \"-u\" ]; then echo 0; else echo \"id $*\" >> \"$STUB_LOG\"; fi\n")
	stubBin(t, stub, "uname", "#!/bin/sh\nif [ \"$1\" = \"-s\" ]; then echo Linux; else /usr/bin/uname \"$@\"; fi\n")
	stubBin(t, stub, "systemctl", "#!/bin/sh\necho \"systemctl $*\" >> \"$STUB_LOG\"\nexit 0\n")
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
