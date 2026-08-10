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
	"strconv"
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

// sysConfigDir/sysDataDir are the sandboxed stand-ins for the real system
// roots (/usr/local/etc|var/burrowee/gateway) that the SYSTEM units name, via
// the BURROWEE_SYSTEM_*_DIR seams. The suite must never create the real ones.
func sysConfigDir(home string) string {
	return filepath.Join(home, "system-etc", "burrowee", "gateway")
}
func sysDataDir(home string) string { return filepath.Join(home, "system-var", "burrowee", "gateway") }

// binDir is $BIN_DIR as this suite's DEFAULT sandbox (installShEnv's
// "BURROWEE_BIN_DIR="+binDir(home)) resolves it — the ONE location,
// root-execed or not, since the libexec-to-$BIN_DIR collapse. It stands in
// for the real, root-owned production default (/usr/local/bin), redirected so
// this suite never touches that real directory — NOT the per-user PREFIX
// override path, which is a different, genuinely different directory now
// that install.sh gates root-exec-surface work on whether PREFIX was set at
// all (see devBinDir, used by the small number of tests that specifically
// exercise that flow).
//
// The suite can prove PLACEMENT and unit CONTENT here; it cannot prove
// OWNERSHIP, because the harness's `sudo` is a pass-through stub and every file
// it "installs as root" belongs to the test user. install.sh knows this (see
// have_real_root) and skips its own ownership assertion on exactly that
// evidence. The ownership predicate itself is tested where it can drive real
// filesystem state: core/binary's IsRootSecure suite and the gateway's
// system_tool tests — and, for the DEFAULT (root-owned) $BIN_DIR path
// specifically, bin_dir_elevation_test.go's chmod-0500 fixtures here.
func binDir(home string) string {
	// Ends in "bin", like every real shape $BIN_DIR takes (/usr/local/bin,
	// $PREFIX/bin): install.sh's migrate_from_legacy hands the migration
	// runner PREFIX="$(dirname "$BIN_DIR")", which only round-trips back to
	// this exact path through the runner's own "${PREFIX:-...}/bin" when the
	// last path component really is "bin".
	return filepath.Join(home, "system", "bin")
}

// devBinDir is $BIN_DIR under an EXPLICIT PREFIX override — the per-user
// developer flow, which since C1's fix is a genuinely different code path
// from binDir's DEFAULT simulation above: PREFIX set at all means no chown,
// no units, no migration, regardless of root/sudo availability. Tests that
// need this flow specifically set "PREFIX="+home+"/.local" themselves (which
// overrides installShEnv's BURROWEE_BIN_DIR — PREFIX always wins in the
// script) and assert against this path.
func devBinDir(home string) string {
	return filepath.Join(home, ".local", "bin")
}

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

	p := filepath.Join(stub, "launchctl")
	if err := os.WriteFile(p, []byte("#!/bin/sh\necho \"launchctl $*\" >> \"$STUB_LOG\"\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write stub launchctl: %v", err)
	}
	// systemctl records like launchctl, but also models a host where one
	// specific call FAILS: STUB_SYSTEMCTL_FAIL=<substring> makes any matching
	// invocation exit non-zero. A supervisor that refuses is the interesting
	// case for the daemon-advance step — new binaries on disk under an old
	// running daemon is the one outcome that looks like a clean install.
	systemctl := "#!/bin/sh\n" +
		"echo \"systemctl $*\" >> \"$STUB_LOG\"\n" +
		"if [ -n \"${STUB_SYSTEMCTL_FAIL:-}\" ]; then\n" +
		"    case \"$*\" in *\"$STUB_SYSTEMCTL_FAIL\"*) echo \"stub: refusing systemctl $*\" >&2; exit 1 ;; esac\n" +
		"fi\n" +
		"exit 0\n"
	if err := os.WriteFile(filepath.Join(stub, "systemctl"), []byte(systemctl), 0o755); err != nil {
		t.Fatalf("write stub systemctl: %v", err)
	}
	writeSudoStub(t, stub)
	return stub
}

// forcedOSes are the two platform branches install.sh carries. A test that
// ranges over this slice exercises BOTH of them on whatever host the suite runs
// on — which is the whole point of stubInitSystemFor below.
var forcedOSes = []string{"darwin", "linux"}

// stubInitSystemFor is stubInitSystem with `uname -s` pinned to goos, so a test
// drives the platform branch install.sh takes instead of inheriting the test
// host's.
//
// This is the seam the suite was missing. Every other test here picks its
// ASSERTIONS with runtime.GOOS while install.sh picks its BEHAVIOUR with
// `uname -s`, so on a macOS release machine the entire Linux half of
// render_units and load_units was unreachable: the systemd unit body, the
// systemctl call sequence, and the Linux legacy-unit teardown all shipped
// having never once been executed by the suite that "covers" them. That is the
// same blindness that let the `stat -f` dialect bug reach every Linux host, and
// it is how load_units went to production without a `systemctl restart` of the
// gateway — a gap no assertion could catch because no assertion ran.
//
// The sibling edge suite has stubbed uname since its first render test
// (inner/edge/install_test/render_test.go); this is that pattern, ported.
func stubInitSystemFor(t *testing.T, goos string) string {
	t.Helper()
	stub := stubInitSystem(t)
	stubUname(t, stub, goos)
	// The Darwin branch strips the quarantine xattr; stub it so a forced-Darwin
	// run is not silently different on a host that has no xattr at all.
	if err := os.WriteFile(filepath.Join(stub, "xattr"), []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write stub xattr: %v", err)
	}
	return stub
}

// stubUname pins `uname -s` in dir to the kernel name matching goos, delegating
// every other uname invocation to the real binary.
func stubUname(t *testing.T, dir, goos string) {
	t.Helper()
	var kernel string
	switch goos {
	case "darwin":
		kernel = "Darwin"
	case "linux":
		kernel = "Linux"
	default:
		t.Fatalf("stubUname: unsupported goos %q", goos)
	}
	body := "#!/bin/sh\nif [ \"$1\" = \"-s\" ]; then echo " + kernel + "; else /usr/bin/uname \"$@\"; fi\n"
	if err := os.WriteFile(filepath.Join(dir, "uname"), []byte(body), 0o755); err != nil {
		t.Fatalf("write stub uname: %v", err)
	}
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
// HOME/PATH plus the system-unit dir seams, the DEFAULT $BIN_DIR redirect,
// and the stub call log.
//
// BURROWEE_BIN_DIR, not PREFIX: this suite's default posture is the DEFAULT,
// root-owned install path (units, migration, root-secure verification —
// what most of this suite exercises), redirected away from the real
// /usr/local/bin. Setting PREFIX here instead would make every test that
// does not override it look like an explicit per-user PREFIX flow, which
// since C1's fix gets no units and no migration at all — that was exactly
// the defect this fixture shape used to hide (see bin_dir_default_test.go's
// and prefix_override_test.go's headers). Tests exercising the developer
// PREFIX flow specifically pass "PREFIX="+home+"/.local" as extraEnv, which
// overrides BURROWEE_BIN_DIR entirely — install.sh's own PREFIX-always-wins
// rule, not a Go-side precedence trick.
func installShEnv(home, stubDir string, extraEnv ...string) []string {
	env := []string{
		"HOME=" + home,
		"BURROWEE_BIN_DIR=" + binDir(home),
		"PATH=" + stubDir + ":/usr/bin:/bin",
		"STUB_LOG=" + filepath.Join(home, "stub-calls.log"),
		"BURROWEE_LAUNCHD_DIR=" + launchdDir(home),
		"BURROWEE_SYSTEMD_DIR=" + systemdDir(home),
		"BURROWEE_SYSTEM_CONFIG_DIR=" + sysConfigDir(home),
		"BURROWEE_SYSTEM_DATA_DIR=" + sysDataDir(home),
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

// assertNotContains asserts that s contains none of the substrings in unwanted.
// The root-scheme unit assertions need this: a test that only checks the new
// fields are present would still pass with a stale UserName left beside them,
// and that leftover is exactly what makes the slot look legacy-owned.
func assertNotContains(t *testing.T, s string, unwanted ...string) {
	t.Helper()
	for _, w := range unwanted {
		if strings.Contains(s, w) {
			t.Errorf("expected content NOT to contain %q\ngot:\n%s", w, s)
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
// both SYSTEM service unit files in the ROOT-SCHEME shape the gateway's own
// renderer emits: no run-as user, no HOME, the two path roots passed
// explicitly, logs under the system data root, and an ExecStart naming
// $BIN_DIR.
//
// SINCE THE LIBEXEC-TO-$BIN_DIR COLLAPSE this suite's fixed PREFIX
// (installShEnv: home+"/.local") means $BIN_DIR and what used to be the
// SEPARATE per-user bin dir are the identical path — this file no longer has
// two directories to assert one against the other from inside one run. That
// is not a coverage gap this test can paper over: production's real
// separation (a root-owned DEFAULT vs an explicit per-user PREFIX override)
// is proven elsewhere — the static default-pin test (both scripts agree on
// "/usr/local") and bin_dir_elevation_test.go's chmod-0500 fixtures, which
// drive install.sh's actual elevation decision against a $BIN_DIR this
// process genuinely cannot write, the nearest an unprivileged test can get to
// "root-owned" without touching a real system directory.
//
// The remaining UserName/HOME/logs absence assertions still carry real
// weight: a unit that records a UserName runs the daemon as that user (which
// cannot read the root-owned identity) and reads as legacy-owned to both
// unit-writers' ownership guards, flapping the service between installers on
// every refresh.
//
// Both platform branches run here, on every host: the systemd half used to be
// dead code on this suite's macOS release machine (see stubInitSystemFor).
func TestInstallShWritesBothUnits(t *testing.T) {
	for _, goos := range forcedOSes {
		t.Run(goos, func(t *testing.T) { testInstallShWritesBothUnits(t, goos) })
	}
}

func testInstallShWritesBothUnits(t *testing.T, goos string) {
	home := t.TempDir()
	stub := stubInitSystemFor(t, goos)
	seedMigrateCapableCLI(t, home)

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	bin := binDir(home)
	username := currentUsername(t)
	logDir := filepath.Join(sysDataDir(home), "logs")

	if goos == "darwin" {
		core := readFile(t, filepath.Join(launchdDir(home), "com.burrowee.gateway.plist"))
		upd := readFile(t, filepath.Join(launchdDir(home), "com.burrowee.gateway.updater.plist"))

		assertContains(t, core,
			"<string>com.burrowee.gateway</string>",
			"<string>"+bin+"/burrowee-gateway</string>",
			"<string>--no-open</string>",
			"<string>--config-dir</string><string>"+sysConfigDir(home)+"</string>",
			"<string>--data-dir</string><string>"+sysDataDir(home)+"</string>",
			"<key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>",
			"<key>WorkingDirectory</key><string>/tmp</string>",
			"<key>KeepAlive</key><dict><key>PathState</key><dict><key>"+bin+"/burrowee-gateway</key><true/></dict></dict>",
			"<string>"+filepath.Join(logDir, "gateway.log")+"</string>",
			"<string>"+filepath.Join(logDir, "gateway.err.log")+"</string>",
		)
		assertNotContains(t, core,
			"<key>UserName</key>",
			"<key>GroupName</key>",
			"<key>InitGroups</key>",
			"<key>HOME</key>",
			home+"/.burrowee/gateway/logs",
		)
		assertContains(t, upd,
			"<string>com.burrowee.gateway.updater</string>",
			"<string>"+bin+"/burrowee-gateway-updater</string>",
			"<string>run</string>",
			"<key>KeepAlive</key><dict><key>PathState</key><dict><key>"+bin+"/burrowee-gateway-updater</key><true/></dict></dict>",
			"<string>"+filepath.Join(logDir, "updater.log")+"</string>",
			"<string>"+filepath.Join(logDir, "updater.err.log")+"</string>",
		)
		assertNotContains(t, upd,
			"<key>UserName</key>",
			"<key>HOME</key>",
			// The updater resolves its own roots under root's euid; passing
			// them would be a second place to keep in step for no gain.
			"--config-dir",
			home+"/.burrowee/gateway/logs",
		)
		// The run-as user must not appear anywhere in either unit.
		assertNotContains(t, core, ">"+username+"<")
		assertNotContains(t, upd, ">"+username+"<")
	} else {
		core := readFile(t, filepath.Join(systemdDir(home), "burrowee-gateway.service"))
		upd := readFile(t, filepath.Join(systemdDir(home), "burrowee-gateway-updater.service"))

		assertContains(t, core,
			"Description=burrowee-gateway",
			"ExecStart="+bin+"/burrowee-gateway --no-open --config-dir "+sysConfigDir(home)+" --data-dir "+sysDataDir(home),
			"Restart=always",
			"RestartSec=2",
			"TimeoutStopSec=330",
			"WantedBy=multi-user.target",
		)
		assertNotContains(t, core,
			"User=",
			"Group=",
			"Environment=HOME=",
		)
		assertContains(t, upd,
			"Description=burrowee-gateway-updater",
			"ExecStart="+bin+"/burrowee-gateway-updater run",
			"Restart=always",
			"WantedBy=multi-user.target",
		)
		assertNotContains(t, upd,
			"User=",
			"Environment=HOME=",
			"--config-dir",
		)
	}
}

// TestInstallShCreatesSystemLogDir verifies the units' log directory is
// pre-created under the system data root, as root. launchd redirects
// StandardOutPath at exec: a missing parent there is not a log that shows up
// late, it is a daemon that fails to spawn. The Go side's
// ensureSystemUnitLogDir does the same, so an install via either writer leaves
// the same tree.
func TestInstallShCreatesSystemLogDir(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	logDir := filepath.Join(sysDataDir(home), "logs")
	info, err := os.Stat(logDir)
	if err != nil {
		t.Fatalf("system unit log dir not created at %s: %v", logDir, err)
	}
	if !info.IsDir() {
		t.Fatalf("%s is not a directory", logDir)
	}
	// The data root holds gateway.db and the register/console sockets. It is
	// created 0700 so that a permissive umask on the parent can never leave
	// the store world-readable.
	if perm := info.Mode().Perm(); perm != 0o700 {
		t.Errorf("log dir mode = %04o, want 0700", perm)
	}
	if di, err := os.Stat(sysDataDir(home)); err != nil {
		t.Errorf("stat system data root: %v", err)
	} else if perm := di.Mode().Perm(); perm != 0o700 {
		t.Errorf("system data root mode = %04o, want 0700", perm)
	}
	// Nothing may be left in the old per-user location.
	if _, err := os.Stat(filepath.Join(home, ".burrowee", "gateway", "logs")); err == nil {
		t.Errorf("per-user log dir still created at $GW_HOME/logs")
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

	binDir := binDir(home)
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
// (no `--now`), no explicit updater restart — and, since the daemon-advancing
// step was added, no `restart burrowee-gateway.service` either. Both branches
// run on every host.
func TestInstallShNoRestartStagesWithoutKicking(t *testing.T) {
	for _, goos := range forcedOSes {
		t.Run(goos, func(t *testing.T) { testInstallShNoRestartStagesWithoutKicking(t, goos) })
	}
}

func testInstallShNoRestartStagesWithoutKicking(t *testing.T, goos string) {
	home := t.TempDir()
	stub := stubInitSystemFor(t, goos)
	seedMigrateCapableCLI(t, home)

	out := runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1", "BURROWEE_NO_RESTART=1")
	assertContains(t, out, "BURROWEE_NO_RESTART set — units staged (not restarted)")

	calls := readFile(t, filepath.Join(home, "stub-calls.log"))
	if goos == "darwin" {
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
		if strings.Contains(calls, "enable --now") ||
			strings.Contains(calls, "restart burrowee-gateway.service") ||
			strings.Contains(calls, "restart burrowee-gateway-updater.service") {
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
	seedMigrateCapableCLI(t, home)

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

	binDir := binDir(home)
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
// succeeds and the legacy per-user unit is replaced by the root-scheme one.
//
// The replacement records NO owner at all — not the current user. That is the
// point of the root scheme: the slot stops belonging to anybody, so the next
// installer (whoever runs it) sees a free slot instead of a unit to contest.
func TestInstallShCrossUserOverrideForced(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)
	path := seedForeignUnit(t, home)

	out := runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1", "BURROWEE_FORCE_SERVICE_OVERRIDE=1")

	assertContains(t, out, "overriding gateway service previously installed for user 'someone-else'")
	got := readFile(t, path)
	if strings.Contains(got, "someone-else") {
		t.Errorf("unit still records the previous owner:\n%s", got)
	}
	if runtime.GOOS == "darwin" {
		assertContains(t, got, "<string>com.burrowee.gateway</string>")
		assertNotContains(t, got, "<key>UserName</key>")
	} else {
		assertContains(t, got, "Description=burrowee-gateway")
		assertNotContains(t, got, "User=")
	}
	assertNotContains(t, got, ">"+currentUsername(t)+"<")
}

// TestInstallShRootSchemeUnitIsAFreeSlot verifies the consent guard treats an
// already-installed ROOT-SCHEME unit as a free slot: a second run (as would
// happen for any user on the host) replaces it silently, with no prompt and no
// force env. This mirrors the Go side's UnitOwnerRootScheme ruling — a unit
// that runs as root belongs to no user, so there is nothing to contest.
func TestInstallShRootSchemeUnitIsAFreeSlot(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")
	out := runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	assertNotContains(t, out, "belongs to user", "overriding gateway service")
	// Identical content the second time: place_unit must report "unchanged"
	// rather than rewriting, or every refresh would bootout a live daemon.
	assertContains(t, out, "(unchanged)")
}

// TestInstallShMigratesLegacyUserUnits verifies that a units-only run removes
// the old per-user unit files (LaunchAgents / systemd --user) and issues the
// legacy teardown calls.
func TestInstallShMigratesLegacyUserUnits(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)

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

// stageInstaller copies the real install.sh into dir, so a test can plant a
// fake migrations/ beside it. install.sh resolves the migration relative to its
// OWN path (not cwd — `service install` re-runs the kept copy from an arbitrary
// working directory), so the two files have to sit together.
func stageInstaller(t *testing.T, dir string) string {
	t.Helper()
	body, err := os.ReadFile(installShPath(t))
	if err != nil {
		t.Fatalf("read install.sh: %v", err)
	}
	staged := filepath.Join(dir, "install.sh")
	if err := os.WriteFile(staged, body, 0o755); err != nil {
		t.Fatalf("stage install.sh: %v", err)
	}
	return staged
}

// shQuote single-quotes s for embedding in a generated shell stub.
func shQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// stageMigration plants a fake migrations/run.sh beside a staged installer. It
// records the environment it was handed (one "KEY=VALUE" per line) and exits with
// exitCode, so a test can assert the hand-off, the "migrations ran" contract
// (exit 2) and the failure path without running a real migration.
func stageMigration(t *testing.T, dir, logPath string, exitCode int) {
	t.Helper()
	mig := filepath.Join(dir, "migrations")
	if err := os.MkdirAll(mig, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\n" +
		"_kept=no; [ -f \"$GW_HOME/install.sh\" ] && [ -f \"$GW_HOME/migrations/run.sh\" ] && _kept=yes\n" +
		"{ echo \"GW_HOME=$GW_HOME\"\n" +
		"  echo \"KEPT_INSTALLER=$_kept\"\n" +
		"  echo \"PREFIX=${PREFIX:-}\"\n" +
		"  echo \"BURROWEE_SYSTEM_CONFIG_DIR=$BURROWEE_SYSTEM_CONFIG_DIR\"\n" +
		"  echo \"BURROWEE_SYSTEM_DATA_DIR=$BURROWEE_SYSTEM_DATA_DIR\"\n" +
		"  echo \"SUDO=${SUDO:-}\"\n" +
		"} >> " + shQuote(logPath) + "\n" +
		"echo migration-ran\nexit " + strconv.Itoa(exitCode) + "\n"
	if err := os.WriteFile(filepath.Join(mig, "run.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

// runStaged runs a STAGED install.sh (one with a fake migrations/ beside it).
// workDir and home are separate on purpose: update mode runs with cwd = the
// unzipped bundle while $HOME (and so PREFIX and every seam) stays the operator's
// — collapsing them installs the binaries into the bundle instead of the host.
func runStaged(t *testing.T, script, workDir, home, stubDir string, extraEnv ...string) (string, error) {
	t.Helper()
	return runStagedArgs(t, script, workDir, home, stubDir, nil, extraEnv...)
}

// runStagedArgs is runStaged with positional script arguments. install.sh's update
// mode reads --version from ARGV, not the environment, so a test that needs it must
// pass it here — putting it in extraEnv leaves _install_version empty and any
// assertion about the recorded version passes for the wrong reason.
func runStagedArgs(t *testing.T, script, workDir, home, stubDir string, scriptArgs []string, extraEnv ...string) (string, error) {
	t.Helper()
	cmd := exec.Command("sh", append([]string{script}, scriptArgs...)...)
	cmd.Dir = workDir
	cmd.Env = installShEnv(home, stubDir, extraEnv...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// seedMigrateCapableCLI stages an ALREADY-INSTALLED host for a units-only run:
// every binary present AT $BIN_DIR ALREADY, and a burrowee-gateway-cli that
// answers `migrate --help`.
//
// Both halves are preconditions of the mode, not conveniences. The cli, because
// units-only places no binaries, so the one already on disk is what the runner
// probes and a host that cannot migrate must be refused BEFORE the root-scheme
// units are written (assert_can_migrate).
//
// USE THIS when the test's subject is something OTHER than the copy itself
// (unit content, ownership refusal, stale-unit rewrite) — it deliberately
// starts from a $BIN_DIR that is already correct, so ensure_root_exec_surface
// has nothing to DO, and a test that needs to observe the copy happening
// would pass even if that copy were deleted. For that, use
// seedMigrateCapableCLIAtDevBinDir below instead.
func seedMigrateCapableCLI(t *testing.T, home string) {
	t.Helper()
	dir := binDir(home)
	seedInstalled(t, dir, allBinsContent("#!/bin/sh\nexit 0\n"))
	if err := os.WriteFile(filepath.Join(dir, "burrowee-gateway-cli"), []byte(cliWithMigrate), 0o755); err != nil {
		t.Fatal(err)
	}
}

// seedMigrateCapableCLIAtDevBinDir is seedMigrateCapableCLI's fixture staged
// at devBinDir(home) (root_bin_source's third fallback, the historical
// per-user default) instead of binDir(home) ($BIN_DIR itself).
//
// USE THIS when the test's subject IS ensure_root_exec_surface's copy: with
// nothing sitting at $BIN_DIR beforehand, a units-only run can only pass by
// genuinely reading root_bin_source's fallback and copying from it — seeding
// directly at $BIN_DIR would make that placement a no-op before the run even
// starts, which is exactly the vacuity this exists to avoid.
func seedMigrateCapableCLIAtDevBinDir(t *testing.T, home string) {
	t.Helper()
	dir := devBinDir(home)
	seedInstalled(t, dir, allBinsContent("#!/bin/sh\nexit 0\n"))
	if err := os.WriteFile(filepath.Join(dir, "burrowee-gateway-cli"), []byte(cliWithMigrate), 0o755); err != nil {
		t.Fatal(err)
	}
}

// migrationLog returns what the fake migration recorded, or "" if it never ran.
func migrationLog(t *testing.T, logPath string) string {
	t.Helper()
	b, err := os.ReadFile(logPath)
	if os.IsNotExist(err) {
		return ""
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// TestInstallShRunsTheMigrationBeforeLoadingUnits: the migration stops the
// gateway so gateway.db is copied at rest, and load_units is what starts it
// again — so running it after would copy a live store, or never run at all.
func TestInstallShRunsTheMigrationBeforeLoadingUnits(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	bundle := t.TempDir()
	script := stageInstaller(t, bundle)
	logPath := filepath.Join(t.TempDir(), "migration.log")
	seedMigrateCapableCLI(t, home)
	stageMigration(t, bundle, logPath, 0)

	out, err := runStaged(t, script, home, home, stub, "BURROWEE_UNITS_ONLY=1")
	if err != nil {
		t.Fatalf("install.sh failed: %v\n%s", err, out)
	}

	if migrationLog(t, logPath) == "" {
		t.Fatalf("the migration was never invoked; output:\n%s", out)
	}
	ran := strings.Index(out, "migration-ran")
	load := "launchctl bootstrap"
	if runtime.GOOS != "darwin" {
		load = "systemctl"
	}
	// The stub calls are logged to a file, but their stdout is not in `out`;
	// compare against the unit-write line instead, which load_units follows.
	started := strings.Index(readFile(t, filepath.Join(home, "stub-calls.log")), load)
	if ran < 0 {
		t.Fatalf("migration output missing:\n%s", out)
	}
	if started < 0 {
		t.Fatalf("units were never loaded; calls:\n%s", readFile(t, filepath.Join(home, "stub-calls.log")))
	}
}

// TestInstallShHandsTheMigrationItsRoots: the migration must act on the same
// roots the units name. Letting it fall back to its own euid-based defaults
// would migrate into a different tree than the daemon reads, and under the test
// seams it would escape the sandbox entirely.
//
// PREFIX is asserted too, and it is not the same claim as the others: it must
// be dirname($BIN_DIR), NOT reconstructed from a hardcoded fallback
// (migrate_from_legacy used to pass PREFIX="${PREFIX:-$HOME/.local}"
// regardless of what $BIN_DIR actually resolved to — the real /usr/local, or
// this test's BURROWEE_BIN_DIR redirect — so the migration runner would
// compute a DIFFERENT $BIN_DIR than this run just placed everything into).
// dirname($BIN_DIR) round-trips through the runner's own
// "${PREFIX:-...}/bin" exactly, which is what makes this assertion able to
// fail: a stale hardcoded fallback would still log SOME PREFIX value, just
// the wrong one.
func TestInstallShHandsTheMigrationItsRoots(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	bundle := t.TempDir()
	script := stageInstaller(t, bundle)
	logPath := filepath.Join(t.TempDir(), "migration.log")
	seedMigrateCapableCLI(t, home)
	stageMigration(t, bundle, logPath, 0)

	if _, err := runStaged(t, script, home, home, stub, "BURROWEE_UNITS_ONLY=1"); err != nil {
		t.Fatalf("install.sh: %v", err)
	}

	assertContains(t, migrationLog(t, logPath),
		"GW_HOME="+filepath.Join(home, ".burrowee", "gateway"),
		"PREFIX="+filepath.Dir(binDir(home)),
		"BURROWEE_SYSTEM_CONFIG_DIR="+sysConfigDir(home),
		"BURROWEE_SYSTEM_DATA_DIR="+sysDataDir(home),
	)
}

// TestInstallShForwardsItsSudoSeamToTheMigration: install.sh has its own root
// discipline (run_root: direct when root, prompting sudo on a tty, `sudo -n`
// otherwise). The migration elevates too, so without the seam it would fall back
// to a bare prompting sudo — from a curl-pipe install with no tty, or from a
// daemon, where the surrounding script guarantees it never prompts.
func TestInstallShForwardsItsSudoSeamToTheMigration(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	bundle := t.TempDir()
	script := stageInstaller(t, bundle)
	logPath := filepath.Join(t.TempDir(), "migration.log")
	seedMigrateCapableCLI(t, home)
	stageMigration(t, bundle, logPath, 0)

	if _, err := runStaged(t, script, home, home, stub, "BURROWEE_UNITS_ONLY=1", "SUDO=/stub/sudo"); err != nil {
		t.Fatalf("install.sh: %v", err)
	}

	assertContains(t, migrationLog(t, logPath), "SUDO=/stub/sudo")
}

// TestInstallShAbortsWhenTheMigrationFails: carrying on would start the new root
// units against a config root with no identity — the daemon then either refuses
// to start or mints a fresh relay_ed.key, re-registering the host as a NEW node
// and orphaning its console pairing, targets and domains.
func TestInstallShAbortsWhenTheMigrationFails(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	bundle := t.TempDir()
	script := stageInstaller(t, bundle)
	logPath := filepath.Join(t.TempDir(), "migration.log")
	seedMigrateCapableCLI(t, home)
	stageMigration(t, bundle, logPath, 1)

	out, err := runStaged(t, script, home, home, stub, "BURROWEE_UNITS_ONLY=1")
	if err == nil {
		t.Fatalf("install.sh succeeded despite a failing migration:\n%s", out)
	}
	if !strings.Contains(out, "migration failed") {
		t.Errorf("no explanation of the abort:\n%s", out)
	}
	// Nothing may have been started: the units were rendered before the
	// migration, but loading them is what would bring up a broken daemon.
	calls := ""
	if b, readErr := os.ReadFile(filepath.Join(home, "stub-calls.log")); readErr == nil {
		calls = string(b)
	}
	for _, forbidden := range []string{"bootstrap", "enable --now"} {
		if strings.Contains(calls, forbidden) {
			t.Errorf("units were loaded after a failed migration (%q):\n%s", forbidden, calls)
		}
	}
}

// TestInstallShToleratesAMissingMigration: BURROWEE_UNITS_ONLY re-runs the copy
// kept at $GW_HOME, and an install predating the migrations/ dir has none beside
// it. A missing migration is "nothing to do", not a broken install.
func TestInstallShToleratesAMissingMigration(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)
	bundle := t.TempDir()
	script := stageInstaller(t, bundle) // no stageMigration

	if _, err := runStaged(t, script, home, home, stub, "BURROWEE_UNITS_ONLY=1"); err != nil {
		t.Fatalf("install.sh failed with no migration present: %v", err)
	}
}
