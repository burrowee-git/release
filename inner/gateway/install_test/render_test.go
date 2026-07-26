// Package install_test is a Go test harness that runs install.sh in a sandbox
// HOME with stubbed sudo/launchctl/systemctl (and sandboxed system-unit dirs
// via the BURROWEE_LAUNCHD_DIR / BURROWEE_SYSTEMD_DIR test seams) to verify
// unit rendering, fresh install, uninstall, legacy migration, and the
// cross-user override guard (D3a). UPDATE mode tests live in D3b
// (update_test.go).
package install_test

import (
	"os"
	"os/exec"
	"os/user"
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

// launchdDir/systemdDir are the sandboxed system-unit locations a test HOME
// maps to (via the BURROWEE_*_DIR seams).
func launchdDir(home string) string { return filepath.Join(home, "LaunchDaemons") }
func systemdDir(home string) string { return filepath.Join(home, "systemd-system") }

// currentUsername is the user install.sh's `id -un` resolves while under test.
func currentUsername(t *testing.T) string {
	t.Helper()
	u, err := user.Current()
	if err != nil {
		t.Fatalf("resolve current user: %v", err)
	}
	return u.Username
}

// stubInitSystem creates a temp directory containing fake launchctl and
// systemctl scripts that record their arguments and exit 0, plus a sudo stub
// that records and then EXECUTES its command (so root-gated writes land in
// the sandboxed unit dirs). Returns the directory (prepend to PATH).
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
	writeSudoStub(t, stub)
	return stub
}

// writeSudoStub drops a pass-through `sudo` into dir: it records the call,
// strips a leading -n, and executes the rest.
func writeSudoStub(t *testing.T, dir string) {
	t.Helper()
	content := "#!/bin/sh\necho \"sudo $*\" >> \"$STUB_LOG\"\n[ \"$1\" = \"-n\" ] && shift\nexec \"$@\"\n"
	if err := os.WriteFile(filepath.Join(dir, "sudo"), []byte(content), 0o755); err != nil {
		t.Fatalf("write stub sudo: %v", err)
	}
}

// installShEnv is the base environment for running install.sh in a sandbox:
// HOME/PREFIX/PATH plus the system-unit dir seams and the stub call log.
func installShEnv(home, stubDir string, extraEnv ...string) []string {
	env := []string{
		"HOME=" + home,
		"PREFIX=" + home + "/.local",
		"PATH=" + stubDir + ":/usr/bin:/bin",
		"STUB_LOG=" + filepath.Join(home, "stub-calls.log"),
		"BURROWEE_LAUNCHD_DIR=" + launchdDir(home),
		"BURROWEE_SYSTEMD_DIR=" + systemdDir(home),
	}
	return append(env, extraEnv...)
}

// runInstallSh runs install.sh in a sandbox HOME.  extraEnv is a list of
// "KEY=VALUE" strings appended to the process environment.  Returns combined
// stdout+stderr output.
func runInstallSh(t *testing.T, home, stubDir string, extraEnv ...string) string {
	t.Helper()
	cmd := exec.Command("sh", installShPath(t))
	cmd.Dir = home // cwd = home (no binaries needed for units-only)
	cmd.Env = installShEnv(home, stubDir, extraEnv...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Logf("install.sh output:\n%s", out)
		t.Fatalf("install.sh failed: %v", err)
	}
	return string(out)
}

// runInstallShExpectFail is like runInstallSh but requires a non-zero exit.
func runInstallShExpectFail(t *testing.T, home, stubDir string, extraEnv ...string) string {
	t.Helper()
	cmd := exec.Command("sh", installShPath(t))
	cmd.Dir = home
	cmd.Env = installShEnv(home, stubDir, extraEnv...)
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("install.sh succeeded, want failure; output:\n%s", out)
	}
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
		"burrowee-gateway-updater",
	}
	for _, b := range bins {
		p := filepath.Join(dir, b)
		if err := os.WriteFile(p, []byte("#!/bin/sh\necho "+b+"\n"), 0o755); err != nil {
			t.Fatalf("seed bin %s: %v", b, err)
		}
	}
}

// TestInstallShWritesBothUnits verifies that BURROWEE_UNITS_ONLY=1 renders
// both SYSTEM service unit files with the correct labels, run-as user, and
// ExecStart paths, for the host OS only.
func TestInstallShWritesBothUnits(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	binDir := home + "/.local/bin"
	username := currentUsername(t)

	if runtime.GOOS == "darwin" {
		core := readFile(t, filepath.Join(launchdDir(home), "com.burrowee.gateway.plist"))
		upd := readFile(t, filepath.Join(launchdDir(home), "com.burrowee.gateway.updater.plist"))

		assertContains(t, core,
			"<string>com.burrowee.gateway</string>",
			"<string>"+binDir+"/burrowee-gateway</string>",
			"<string>--no-open</string>",
			"<key>UserName</key><string>"+username+"</string>",
			"<key>InitGroups</key><true/>",
			"<key>HOME</key><string>"+home+"</string>",
			"<key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>",
			"<key>WorkingDirectory</key><string>/tmp</string>",
			"<key>KeepAlive</key><dict><key>PathState</key><dict><key>"+binDir+"/burrowee-gateway</key><true/></dict></dict>",
			"<string>"+home+"/.burrowee/gateway/logs/gateway.log</string>",
			"<string>"+home+"/.burrowee/gateway/logs/gateway.err.log</string>",
		)
		assertContains(t, upd,
			"<string>com.burrowee.gateway.updater</string>",
			"<string>"+binDir+"/burrowee-gateway-updater</string>",
			"<string>run</string>",
			"<key>UserName</key><string>"+username+"</string>",
			"<key>KeepAlive</key><dict><key>PathState</key><dict><key>"+binDir+"/burrowee-gateway-updater</key><true/></dict></dict>",
			"<string>"+home+"/.burrowee/gateway/logs/updater.log</string>",
			"<string>"+home+"/.burrowee/gateway/logs/updater.err.log</string>",
		)
	} else {
		core := readFile(t, filepath.Join(systemdDir(home), "burrowee-gateway.service"))
		upd := readFile(t, filepath.Join(systemdDir(home), "burrowee-gateway-updater.service"))

		assertContains(t, core,
			"Description=burrowee-gateway",
			"User="+username,
			"Environment=HOME="+home,
			"ExecStart="+binDir+"/burrowee-gateway --no-open",
			"Restart=always",
			"TimeoutStopSec=330",
			"WantedBy=multi-user.target",
		)
		assertContains(t, upd,
			"Description=burrowee-gateway-updater",
			"User="+username,
			"ExecStart="+binDir+"/burrowee-gateway-updater run",
			"Restart=always",
			"WantedBy=multi-user.target",
		)
	}
}

// TestInstallShFreshInstall verifies that fresh mode (all dummy bins present)
// installs them into BIN_DIR, writes both system unit files, and leaves a
// self-copy at $GW_HOME/install.sh.
func TestInstallShFreshInstall(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)

	// Seed dummy binaries in a staging dir that will be cwd for the script.
	staging := t.TempDir()
	seedDummyBins(t, staging)

	// Run install.sh from the staging dir (script uses "./$b" to find bins).
	cmd := exec.Command("sh", installShPath(t))
	cmd.Dir = staging
	cmd.Env = installShEnv(home, stub)
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
		"burrowee-gateway-updater",
	} {
		if _, err := os.Stat(filepath.Join(binDir, b)); err != nil {
			t.Errorf("binary not installed: %s: %v", b, err)
		}
	}

	// Self-copy present.
	if _, err := os.Stat(filepath.Join(home, ".burrowee/gateway/install.sh")); err != nil {
		t.Errorf("self-copy missing at $GW_HOME/install.sh: %v", err)
	}

	// Both system unit files written.
	if runtime.GOOS == "darwin" {
		if _, err := os.Stat(filepath.Join(launchdDir(home), "com.burrowee.gateway.plist")); err != nil {
			t.Errorf("core plist missing: %v", err)
		}
		if _, err := os.Stat(filepath.Join(launchdDir(home), "com.burrowee.gateway.updater.plist")); err != nil {
			t.Errorf("updater plist missing: %v", err)
		}
	} else {
		if _, err := os.Stat(filepath.Join(systemdDir(home), "burrowee-gateway.service")); err != nil {
			t.Errorf("core service missing: %v", err)
		}
		if _, err := os.Stat(filepath.Join(systemdDir(home), "burrowee-gateway-updater.service")); err != nil {
			t.Errorf("updater service missing: %v", err)
		}
	}
}

// TestInstallShNoRestartStagesWithoutKicking verifies BURROWEE_NO_RESTART=1
// (Task 8 — the local-stage counterpart to the gateway's `update`/`reinstall`
// verbs without --auto) leaves the units installed/enabled but skips the
// "kick a possibly-already-running instance" calls: on Darwin, no
// bootout+re-bootstrap of an already-loaded label; on Linux, plain `enable`
// (no `--now`) and no explicit updater restart.
func TestInstallShNoRestartStagesWithoutKicking(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)

	out := runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1", "BURROWEE_NO_RESTART=1")
	assertContains(t, out, "BURROWEE_NO_RESTART set — units staged (not restarted)")

	calls := readFile(t, filepath.Join(home, "stub-calls.log"))
	if runtime.GOOS == "darwin" {
		// "bootout system/..." is load_units' own kick of an already-loaded
		// label; "bootout gui/..." is remove_legacy_user_units tearing down
		// legacy per-user units (unrelated to this guard) and must still fire.
		if strings.Contains(calls, "bootout system/com.burrowee.gateway") {
			t.Errorf("BURROWEE_NO_RESTART=1: bootout called, want units staged without kicking a running instance:\n%s", calls)
		}
		assertContains(t, calls,
			"launchctl bootstrap system "+launchdDir(home)+"/com.burrowee.gateway.plist",
			"launchctl bootstrap system "+launchdDir(home)+"/com.burrowee.gateway.updater.plist",
		)
	} else {
		if strings.Contains(calls, "enable --now") || strings.Contains(calls, "restart burrowee-gateway-updater.service") {
			t.Errorf("BURROWEE_NO_RESTART=1: enable --now/restart called, want units staged without starting:\n%s", calls)
		}
		assertContains(t, calls,
			"systemctl enable burrowee-gateway.service",
			"systemctl enable burrowee-gateway-updater.service",
		)
	}
}

// TestInstallShDefaultPathDoesNotFlapUnits is the regression guard for the
// BURROWEE_NO_RESTART guard's own blast radius: the staged and restart paths
// must be mutually exclusive. An earlier shape ran the two bootstraps
// unconditionally and THEN the bootout+bootstrap pair, which on a fresh Darwin
// install started the service, stopped it, and started it again — a visible
// flap on every install and reinstall. Each label must be bootstrapped exactly
// once, after its bootout.
func TestInstallShDefaultPathDoesNotFlapUnits(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("launchctl bootout/bootstrap sequencing is Darwin-only")
	}
	home := t.TempDir()
	stub := stubInitSystem(t)

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")
	calls := readFile(t, filepath.Join(home, "stub-calls.log"))

	// The sudo stub records its own "sudo -n launchctl …" line and then execs
	// launchctl, which records "launchctl …" — so every real call appears on
	// two lines. Match whole lines against the bare form to count each once.
	var direct []string
	for _, line := range strings.Split(calls, "\n") {
		if s := strings.TrimSpace(line); strings.HasPrefix(s, "launchctl ") {
			direct = append(direct, s)
		}
	}

	for _, label := range []string{"com.burrowee.gateway", "com.burrowee.gateway.updater"} {
		bootstrap := "launchctl bootstrap system " + launchdDir(home) + "/" + label + ".plist"
		bootout := "launchctl bootout system/" + label

		n, firstBootstrap, firstBootout := 0, -1, -1
		for i, c := range direct {
			switch c {
			case bootstrap:
				n++
				if firstBootstrap < 0 {
					firstBootstrap = i
				}
			case bootout:
				if firstBootout < 0 {
					firstBootout = i
				}
			}
		}
		if n != 1 {
			t.Errorf("%s: bootstrap called %d times, want exactly 1 (unit flap):\n%s", label, n, calls)
		}
		if firstBootout < 0 {
			t.Errorf("%s: no bootout on the default path — a running unit would never advance:\n%s", label, calls)
			continue
		}
		if firstBootstrap >= 0 && firstBootstrap < firstBootout {
			t.Errorf("%s: bootstrap precedes bootout — starts the unit before stopping it:\n%s", label, calls)
		}
	}
}

// TestInstallShUninstall verifies that BURROWEE_UNINSTALL=1 removes binaries
// and both system unit files.
func TestInstallShUninstall(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)

	// First, do a fresh install from a staging dir.
	staging := t.TempDir()
	seedDummyBins(t, staging)

	cmd := exec.Command("sh", installShPath(t))
	cmd.Dir = staging
	cmd.Env = installShEnv(home, stub)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Logf("fresh install output:\n%s", out)
		t.Fatalf("fresh install failed: %v", err)
	}

	// Now uninstall.
	cmd = exec.Command("sh", installShPath(t))
	cmd.Dir = home
	cmd.Env = installShEnv(home, stub, "BURROWEE_UNINSTALL=1")
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
		"burrowee-gateway-updater",
	} {
		p := filepath.Join(binDir, b)
		if _, err := os.Stat(p); err == nil {
			t.Errorf("binary still present after uninstall: %s", p)
		}
	}

	// System unit files removed.
	if runtime.GOOS == "darwin" {
		for _, name := range []string{
			"com.burrowee.gateway.plist",
			"com.burrowee.gateway.updater.plist",
		} {
			p := filepath.Join(launchdDir(home), name)
			if _, err := os.Stat(p); err == nil {
				t.Errorf("unit file still present after uninstall: %s", p)
			}
		}
	} else {
		for _, name := range []string{
			"burrowee-gateway.service",
			"burrowee-gateway-updater.service",
		} {
			p := filepath.Join(systemdDir(home), name)
			if _, err := os.Stat(p); err == nil {
				t.Errorf("unit file still present after uninstall: %s", p)
			}
		}
	}
}

// seedForeignUnit writes a core system unit recorded for a different user
// into the sandboxed unit dir, returning its path.
func seedForeignUnit(t *testing.T, home string) string {
	t.Helper()
	var path, content string
	if runtime.GOOS == "darwin" {
		path = filepath.Join(launchdDir(home), "com.burrowee.gateway.plist")
		content = "<plist version=\"1.0\"><dict>\n  <key>Label</key><string>com.burrowee.gateway</string>\n  <key>UserName</key><string>someone-else</string>\n</dict></plist>\n"
	} else {
		path = filepath.Join(systemdDir(home), "burrowee-gateway.service")
		content = "[Service]\nUser=someone-else\nExecStart=/x/burrowee-gateway --no-open\n"
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// TestInstallShCrossUserOverrideAborts verifies the single-system-slot guard:
// a unit recorded for a different user makes a non-interactive units-only run
// abort with an actionable message, leaving the unit untouched.
func TestInstallShCrossUserOverrideAborts(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	path := seedForeignUnit(t, home)
	before := readFile(t, path)

	out := runInstallShExpectFail(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	assertContains(t, out, "belongs to user 'someone-else'", "BURROWEE_FORCE_SERVICE_OVERRIDE")
	if got := readFile(t, path); got != before {
		t.Errorf("foreign unit was modified on abort:\n%s", got)
	}
}

// TestInstallShCrossUserOverrideForced verifies that
// BURROWEE_FORCE_SERVICE_OVERRIDE=1 takes over a foreign unit: the run
// succeeds and the unit is rewritten for the current user.
func TestInstallShCrossUserOverrideForced(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	path := seedForeignUnit(t, home)

	out := runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1", "BURROWEE_FORCE_SERVICE_OVERRIDE=1")

	assertContains(t, out, "overriding gateway service previously installed for user 'someone-else'")
	got := readFile(t, path)
	if strings.Contains(got, "someone-else") {
		t.Errorf("unit still records the previous owner:\n%s", got)
	}
	username := currentUsername(t)
	if runtime.GOOS == "darwin" {
		assertContains(t, got, "<key>UserName</key><string>"+username+"</string>")
	} else {
		assertContains(t, got, "User="+username)
	}
}

// TestInstallShMigratesLegacyUserUnits verifies that a units-only run removes
// the old per-user unit files (LaunchAgents / systemd --user) and issues the
// legacy teardown calls.
func TestInstallShMigratesLegacyUserUnits(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)

	var legacyPaths []string
	if runtime.GOOS == "darwin" {
		dir := filepath.Join(home, "Library/LaunchAgents")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		for _, name := range []string{
			"com.burrowee.gateway.plist",
			"com.burrowee.gateway.updater.plist",
			"org.burrowee.gateway.plist",
		} {
			p := filepath.Join(dir, name)
			if err := os.WriteFile(p, []byte("<plist/>"), 0o644); err != nil {
				t.Fatal(err)
			}
			legacyPaths = append(legacyPaths, p)
		}
	} else {
		dir := filepath.Join(home, ".config/systemd/user")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		for _, name := range []string{"burrowee-gateway.service", "burrowee-gateway-updater.service"} {
			p := filepath.Join(dir, name)
			if err := os.WriteFile(p, []byte("[Service]\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			legacyPaths = append(legacyPaths, p)
		}
	}

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	for _, p := range legacyPaths {
		if _, err := os.Stat(p); err == nil {
			t.Errorf("legacy per-user unit still present: %s", p)
		}
	}

	calls := readFile(t, filepath.Join(home, "stub-calls.log"))
	if runtime.GOOS == "darwin" {
		assertContains(t, calls, "launchctl bootout gui/")
	} else {
		assertContains(t, calls, "systemctl --user disable --now burrowee-gateway.service")
	}
}
