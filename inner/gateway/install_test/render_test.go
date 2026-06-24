// Package install_test is a Go test harness that runs install.sh in a sandbox
// HOME with stubbed launchctl/systemctl to verify unit rendering, fresh install,
// and uninstall modes (D3a). UPDATE mode tests live in D3b (update_test.go).
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// installShPath resolves the install.sh under test relative to this file.
func installShPath(t *testing.T) string {
	t.Helper()
	// This file lives at inner/gateway/install_test/render_test.go.
	// install.sh is at inner/gateway/install.sh.
	dir, err := filepath.Abs(filepath.Join("..", "install.sh"))
	if err != nil {
		t.Fatalf("resolve install.sh: %v", err)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("install.sh not found at %s: %v", dir, err)
	}
	return dir
}

// stubInitSystem creates a temp directory containing fake launchctl and
// systemctl scripts that record their arguments and exit 0.  Returns the
// directory (prepend to PATH).
func stubInitSystem(t *testing.T) string {
	t.Helper()
	stub := t.TempDir()

	for _, name := range []string{"launchctl", "systemctl"} {
		p := filepath.Join(stub, name)
		content := "#!/bin/sh\necho \"" + name + " $*\" >> \"$STUB_LOG\"\nexit 0\n"
		if err := os.WriteFile(p, []byte(content), 0o755); err != nil {
			t.Fatalf("write stub %s: %v", name, err)
		}
	}
	return stub
}

// runInstallSh runs install.sh in a sandbox HOME.  extraEnv is a list of
// "KEY=VALUE" strings appended to the process environment.  Returns combined
// stdout+stderr output.
func runInstallSh(t *testing.T, home, stubDir string, extraEnv ...string) string {
	t.Helper()
	script := installShPath(t)

	logFile := filepath.Join(home, "stub-calls.log")
	env := []string{
		"HOME=" + home,
		"PREFIX=" + home + "/.local",
		"PATH=" + stubDir + ":/usr/bin:/bin",
		"STUB_LOG=" + logFile,
	}
	env = append(env, extraEnv...)

	cmd := exec.Command("sh", script)
	cmd.Dir = home // cwd = home (no binaries needed for units-only)
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Logf("install.sh output:\n%s", out)
		t.Fatalf("install.sh failed: %v", err)
	}
	return string(out)
}

// runInstallShExpectFail is like runInstallSh but expects a non-zero exit.
func runInstallShExpectFail(t *testing.T, home, stubDir string, extraEnv ...string) string {
	t.Helper()
	script := installShPath(t)
	logFile := filepath.Join(home, "stub-calls.log")
	env := []string{
		"HOME=" + home,
		"PREFIX=" + home + "/.local",
		"PATH=" + stubDir + ":/usr/bin:/bin",
		"STUB_LOG=" + logFile,
	}
	env = append(env, extraEnv...)

	cmd := exec.Command("sh", script)
	cmd.Dir = home
	cmd.Env = env
	out, _ := cmd.CombinedOutput()
	return string(out)
}

// readFile reads a file and returns its content as a string, failing the test
// on any error.
func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}

// assertContains asserts that s contains every substring in want.
func assertContains(t *testing.T, s string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(s, w) {
			t.Errorf("expected content to contain %q\ngot:\n%s", w, s)
		}
	}
}

// seedDummyBins creates dummy executable files for each name in BINS inside dir.
func seedDummyBins(t *testing.T, dir string) {
	t.Helper()
	bins := []string{
		"burrowee",
		"burrowee-gateway",
		"burrowee-gateway-cli",
		"burrowee-gateway-console",
		"burrowee-register",
	}
	for _, b := range bins {
		p := filepath.Join(dir, b)
		if err := os.WriteFile(p, []byte("#!/bin/sh\necho "+b+"\n"), 0o755); err != nil {
			t.Fatalf("seed bin %s: %v", b, err)
		}
	}
}

// TestInstallShWritesBothUnits verifies that BURROWEE_UNITS_ONLY=1 renders
// both service unit files with the correct labels and ExecStart paths, for
// the host OS only.
func TestInstallShWritesBothUnits(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	binDir := home + "/.local/bin"

	if runtime.GOOS == "darwin" {
		core := readFile(t, filepath.Join(home, "Library/LaunchAgents/com.burrowee.gateway.plist"))
		upd := readFile(t, filepath.Join(home, "Library/LaunchAgents/com.burrowee.gateway.updater.plist"))

		assertContains(t, core,
			"<string>com.burrowee.gateway</string>",
			"<string>"+binDir+"/burrowee-gateway</string>",
			"<string>--no-open</string>",
			"<string>"+home+"/.burrowee/gateway/logs/gateway.log</string>",
			"<string>"+home+"/.burrowee/gateway/logs/gateway.err.log</string>",
		)
		assertContains(t, upd,
			"<string>com.burrowee.gateway.updater</string>",
			"<string>"+binDir+"/burrowee-gateway-cli</string>",
			"<string>updater</string>",
			"<string>"+home+"/.burrowee/gateway/logs/updater.log</string>",
			"<string>"+home+"/.burrowee/gateway/logs/updater.err.log</string>",
		)
	} else {
		core := readFile(t, filepath.Join(home, ".config/systemd/user/burrowee-gateway.service"))
		upd := readFile(t, filepath.Join(home, ".config/systemd/user/burrowee-gateway-updater.service"))

		assertContains(t, core,
			"Description=burrowee-gateway",
			"ExecStart="+binDir+"/burrowee-gateway --no-open",
			"TimeoutStopSec=330",
		)
		assertContains(t, upd,
			"Description=burrowee-gateway updater",
			"ExecStart="+binDir+"/burrowee-gateway-cli updater",
		)
	}
}

// TestInstallShFreshInstall verifies that fresh mode (all 5 dummy bins present)
// installs them into BIN_DIR, writes both unit files, and leaves a self-copy
// at $GW_HOME/install.sh.
func TestInstallShFreshInstall(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)

	// Seed dummy binaries in a staging dir that will be cwd for the script.
	staging := t.TempDir()
	seedDummyBins(t, staging)

	// Run install.sh from the staging dir (script uses "./$b" to find bins).
	script := installShPath(t)
	logFile := filepath.Join(home, "stub-calls.log")
	env := []string{
		"HOME=" + home,
		"PREFIX=" + home + "/.local",
		"PATH=" + stub + ":/usr/bin:/bin",
		"STUB_LOG=" + logFile,
	}
	cmd := exec.Command("sh", script)
	cmd.Dir = staging
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Logf("install.sh output:\n%s", out)
		t.Fatalf("install.sh failed: %v", err)
	}

	binDir := home + "/.local/bin"
	for _, b := range []string{
		"burrowee",
		"burrowee-gateway",
		"burrowee-gateway-cli",
		"burrowee-gateway-console",
		"burrowee-register",
	} {
		if _, err := os.Stat(filepath.Join(binDir, b)); err != nil {
			t.Errorf("binary not installed: %s: %v", b, err)
		}
	}

	// Self-copy present.
	if _, err := os.Stat(filepath.Join(home, ".burrowee/gateway/install.sh")); err != nil {
		t.Errorf("self-copy missing at $GW_HOME/install.sh: %v", err)
	}

	// Both unit files written.
	if runtime.GOOS == "darwin" {
		if _, err := os.Stat(filepath.Join(home, "Library/LaunchAgents/com.burrowee.gateway.plist")); err != nil {
			t.Errorf("core plist missing: %v", err)
		}
		if _, err := os.Stat(filepath.Join(home, "Library/LaunchAgents/com.burrowee.gateway.updater.plist")); err != nil {
			t.Errorf("updater plist missing: %v", err)
		}
	} else {
		if _, err := os.Stat(filepath.Join(home, ".config/systemd/user/burrowee-gateway.service")); err != nil {
			t.Errorf("core service missing: %v", err)
		}
		if _, err := os.Stat(filepath.Join(home, ".config/systemd/user/burrowee-gateway-updater.service")); err != nil {
			t.Errorf("updater service missing: %v", err)
		}
	}
}

// TestInstallShUninstall verifies that BURROWEE_UNINSTALL=1 removes binaries
// and both unit files.
func TestInstallShUninstall(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)

	// First, do a fresh install from a staging dir.
	staging := t.TempDir()
	seedDummyBins(t, staging)

	script := installShPath(t)
	logFile := filepath.Join(home, "stub-calls.log")
	baseEnv := []string{
		"HOME=" + home,
		"PREFIX=" + home + "/.local",
		"PATH=" + stub + ":/usr/bin:/bin",
		"STUB_LOG=" + logFile,
	}

	cmd := exec.Command("sh", script)
	cmd.Dir = staging
	cmd.Env = baseEnv
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Logf("fresh install output:\n%s", out)
		t.Fatalf("fresh install failed: %v", err)
	}

	// Now uninstall.
	uninstallEnv := append([]string{"BURROWEE_UNINSTALL=1"}, baseEnv...)
	cmd = exec.Command("sh", script)
	cmd.Dir = home
	cmd.Env = uninstallEnv
	out, err = cmd.CombinedOutput()
	if err != nil {
		t.Logf("uninstall output:\n%s", out)
		t.Fatalf("uninstall failed: %v", err)
	}

	binDir := home + "/.local/bin"
	for _, b := range []string{
		"burrowee",
		"burrowee-gateway",
		"burrowee-gateway-cli",
		"burrowee-gateway-console",
		"burrowee-register",
	} {
		p := filepath.Join(binDir, b)
		if _, err := os.Stat(p); err == nil {
			t.Errorf("binary still present after uninstall: %s", p)
		}
	}

	// Unit files removed.
	if runtime.GOOS == "darwin" {
		for _, name := range []string{
			"com.burrowee.gateway.plist",
			"com.burrowee.gateway.updater.plist",
		} {
			p := filepath.Join(home, "Library/LaunchAgents", name)
			if _, err := os.Stat(p); err == nil {
				t.Errorf("unit file still present after uninstall: %s", p)
			}
		}
	} else {
		for _, name := range []string{
			"burrowee-gateway.service",
			"burrowee-gateway-updater.service",
		} {
			p := filepath.Join(home, ".config/systemd/user", name)
			if _, err := os.Stat(p); err == nil {
				t.Errorf("unit file still present after uninstall: %s", p)
			}
		}
	}
}
