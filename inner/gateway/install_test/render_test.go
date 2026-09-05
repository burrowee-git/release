// Package install_test is a Go test harness that runs install.sh in a sandbox
// HOME with stubbed sudo/launchctl/systemctl/systemd-run (and sandboxed
// system-unit dirs via the BURROWEE_LAUNCHD_DIR / BURROWEE_SYSTEMD_DIR /
// BURROWEE_LIBEXEC_DIR test seams) to verify unit rendering, fresh install,
// uninstall, legacy migration, and the cross-user override guard (D3a). UPDATE
// mode tests live in D3b (update_test.go).
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

// guardShPath resolves guard.sh the same way installShPath resolves
// install.sh — both ship side by side in the real payload (payload.test.sh
// pins the manifest), and guard_arm resolves guard.sh relative to $0 the same
// way ensure_root_exec_surface resolves migrations/.
func guardShPath(t *testing.T) string {
	t.Helper()
	dir, err := filepath.Abs(filepath.Join("..", "guard.sh"))
	if err != nil {
		t.Fatalf("resolve guard.sh: %v", err)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("guard.sh not found at %s: %v", dir, err)
	}
	return dir
}

// launchdDir/systemdDir are the sandboxed system-unit locations a test HOME
// maps to (via the BURROWEE_*_DIR seams).
func launchdDir(home string) string { return filepath.Join(home, "LaunchDaemons") }
func systemdDir(home string) string { return filepath.Join(home, "systemd-system") }

// sysConfigDir/sysDataDir are the sandboxed stand-ins for the real system
// roots (/usr/local/burrowee/etc|var/gateway) that the SYSTEM units name, via
// the BURROWEE_SYSTEM_*_DIR seams. The suite must never create the real ones.
//
// They sit UNDER systemRoot(home), beside binDir(home), in the production
// shape: install.sh derives the tree's parents from these three leaves
// (SYSTEM_ROOT = dirname $BIN_DIR, SYS_ETC_ROOT = dirname $SYS_CONFIG_DIR, …)
// and creates every level with a plain mkdir — no -p — refusing a level whose
// parent is missing. A sandbox shaped like the real tree is what lets the
// suite assert every level's mode (system_tree_test.go) without the
// installer growing a fourth seam that a suite could forget to set.
func sysConfigDir(home string) string { return filepath.Join(systemRoot(home), "etc", "gateway") }
func sysDataDir(home string) string   { return filepath.Join(systemRoot(home), "var", "gateway") }

// systemRoot is the sandboxed /usr/local/burrowee — the one parent bin/, etc/
// and var/ hang off. install.sh never creates or re-modes anything ABOVE it.
func systemRoot(home string) string { return filepath.Join(home, "system") }

// libexecDir is the sandboxed stand-in for guard_arm's real destination
// (/usr/local/libexec/burrowee), via the BURROWEE_LIBEXEC_DIR seam — the one
// directory install.sh writes into that had no seam of its own before the
// guard: without this redirect, arming the guard under test would install a
// real file at that real, root-owned path, which is exactly what every other
// BURROWEE_*_DIR seam in this harness exists to prevent.
func libexecDir(home string) string { return filepath.Join(home, "libexec", "burrowee") }

// binDir is $BIN_DIR as this suite's sandbox (installShEnv's
// "BURROWEE_BIN_DIR="+binDir(home)) resolves it — the ONE location,
// root-execed or not, since the libexec-to-$BIN_DIR collapse, and the ONLY one
// since the prefix collapse. It stands in for the real, root-owned production
// destination (/usr/local/bin), redirected so this suite never touches that
// real directory. There is no second, per-user directory an install can choose
// any more: a PREFIX naming anywhere else is refused (bin_dir_default_test.go,
// prefix_gate_test.go).
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
	return filepath.Join(systemRoot(home), "bin")
}

// legacyBinDir is the sandboxed stand-in for /usr/local/bin — the 0.2 exec
// root the sweep reads — via the BURROWEE_LEGACY_BIN_DIR seam. Never the real
// directory: the machines this suite runs on are live 0.2 hosts, and nothing
// this installer does writes here any more (the link step of spec §6.1 is
// superseded and gone).
func legacyBinDir(home string) string { return filepath.Join(home, "usr-local-bin") }

// devBinDir is the HISTORICAL per-user bin dir ($HOME/.local/bin) — where
// pre-collapse installs put everything, and so where a host arriving at a
// current installer still has its old binaries and its old unit's ExecStart
// pointing. No install writes here any more; it is a fixture location for the
// convergence and root_bin_source-fallback tests, and for asserting that the
// refusal of an explicit PREFIX places nothing.
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

	// launchctl records and exits 0 — with ONE simulated side effect. guard_arm
	// now polls for proof the guard actually STARTED ($TXN_DIR/guard.pid, or a
	// "guard armed" line in guard.log) before letting the install proceed,
	// because `launchctl bootstrap` exiting 0 means the job was LOADED, not
	// that it ran: a guard that dies on exec used to give a green install that
	// restarted nothing. A stub that only records IS that dead guard, so
	// bootstrapping the guard's own plist writes the two artefacts a live guard
	// writes as its first two statements. It still never spawns anything —
	// guardStartSideEffect below reads the transaction directory back out of
	// the plist rather than re-deriving it, so a plist naming the wrong
	// directory still fails the poll.
	// guardVerdictFn — the shell half of the STUB_GUARD_VERDICT seam, shared by
	// both arm stubs below because both are "the supervisor accepted the guard".
	//
	// WHY A REAL DETACHED WRITER AND NOT A PRE-SEEDED PHASE FILE. install.sh's
	// own flow writes `handoff` into that file AFTER the arm returns, so anything
	// this stub wrote at arm time is overwritten a moment later — which is
	// exactly the shape a real guard has, and exactly why the guard is a detached
	// child of the init system rather than something the installer waits on. So
	// the stub forks a watcher that waits for `handoff` to appear and only then
	// writes the verdict, the same order of events a real guard produces.
	//
	// It is opt-in (STUB_GUARD_VERDICT unset = today's behaviour, no guard ever
	// reports) because every other test in this package wants the honest
	// "nothing ever ran" outcome REATTACH_CEILING=0 gives it.
	//
	// The severed-session half of the same fixture is NOT here — it is in
	// writeSudoStub (STUB_GUARD_SEVER), because it has to be synchronous with
	// the handoff and a poll cannot be. See that function's header.
	//
	// tmp-then-mv, like install.sh's own txn_phase: reattach reads this file on a
	// poll, and a plain truncate-and-write is readable empty in between.
	guardVerdictFn := "guard_verdict() {\n" +
		"    [ -n \"${STUB_GUARD_VERDICT:-}\" ] || return 0\n" +
		"    ( _i=0\n" +
		"      while [ \"$_i\" -lt 60 ]; do\n" +
		"        if [ \"$(cat \"$1/phase\" 2>/dev/null)\" = handoff ]; then\n" +
		"            printf '%s\\n' \"$STUB_GUARD_VERDICT\" > \"$1/.stubphase\"\n" +
		"            mv -f \"$1/.stubphase\" \"$1/phase\"\n" +
		"            exit 0\n" +
		"        fi\n" +
		"        sleep 1; _i=$((_i + 1))\n" +
		"      done ) >/dev/null 2>&1 &\n" +
		"}\n"

	p := filepath.Join(stub, "launchctl")
	launchctl := "#!/bin/sh\n" + guardVerdictFn +
		"echo \"launchctl $*\" >> \"$STUB_LOG\"\n" +
		"if [ \"$1\" = bootstrap ]; then\n" +
		"    case \"$3\" in\n" +
		"    *com.burrowee.gateway.guard.plist)\n" +
		"        _txn=\"$(sed -n 's|.*<string>\\(.*/install/[^<]*\\)</string>.*|\\1|p' \"$3\" | head -1)\"\n" +
		"        if [ -n \"$_txn\" ] && [ -d \"$_txn\" ]; then\n" +
		"            echo 4242 > \"$_txn/guard.pid\"\n" +
		"            echo '00:00:00 guard armed for '\"$_txn\" >> \"$_txn/guard.log\"\n" +
		"            guard_verdict \"$_txn\"\n" +
		"        fi\n" +
		"        ;;\n" +
		"    esac\n" +
		"fi\n" +
		"exit 0\n"
	if err := os.WriteFile(p, []byte(launchctl), 0o755); err != nil {
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
	// guard_arm's Linux branch calls this bare, via $PATH, to arm the guard
	// under the real init system's supervision — and this suite's own host is
	// frequently Linux (the shared CI machine), so a fresh-install test with no
	// forced platform reaches this branch for real unless it is stubbed here
	// too. Recording and exiting 0, never actually spawning the guard: a real
	// systemd-run would hand a live transient unit to the HOST's own systemd,
	// which is exactly the shared-machine side effect every other stub here
	// (launchctl, systemctl, sudo) exists to prevent.
	//
	// It DOES write the guard's first two artefacts, for the same reason the
	// launchctl stub above does: guard_arm refuses to proceed on a guard that
	// was accepted but never ran. The transaction directory is systemd-run's
	// last argument.
	systemdRun := "#!/bin/sh\n" + guardVerdictFn +
		"echo \"systemd-run $*\" >> \"$STUB_LOG\"\n" +
		"for _a in \"$@\"; do _txn=\"$_a\"; done\n" +
		"case \"$_txn\" in\n" +
		"*/install/*)\n" +
		"    if [ -d \"$_txn\" ]; then\n" +
		"        echo 4242 > \"$_txn/guard.pid\"\n" +
		"        echo '00:00:00 guard armed for '\"$_txn\" >> \"$_txn/guard.log\"\n" +
		"        guard_verdict \"$_txn\"\n" +
		"    fi\n" +
		"    ;;\n" +
		"esac\n" +
		"exit 0\n"
	if err := os.WriteFile(filepath.Join(stub, "systemd-run"), []byte(systemdRun), 0o755); err != nil {
		t.Fatalf("write stub systemd-run: %v", err)
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
//
// STUB_GUARD_SEVER=1 adds one thing, and it is the only way to reproduce the
// failure this whole design exists for: when the command it is about to run is
// the `mv` that installs phase=handoff, it performs the mv and then KILLS the
// installer, before returning. That is what the restart does to an operator
// whose session is tunnelled through the gateway — the shell does not get to
// run another line.
//
// IT HAS TO BE HERE AND NOT IN A WATCHER. A background watcher polling the
// phase file is a second later, and a second is thousands of statements: an
// installer that is still alive executes whatever sits below the handoff, so a
// state write MOVED below it still lands and the assertion passes on the
// defect. Verified by mutation — with the kill in the watcher, moving
// record_installed_version below `txn_phase handoff` left the severed-session
// test green. Killing from inside the elevation the handoff itself runs
// through is synchronous with the handoff by construction.
//
// The pid comes from the transaction's own installer.pid ($$ as install.sh
// wrote it at txn_begin), which is the same file guard.sh's watch loop polls to
// detect exactly this event on a real host — not $PPID, which is whichever
// subshell happened to invoke this stub.
func writeSudoStub(t *testing.T, dir string) {
	t.Helper()
	content := "#!/bin/sh\n" +
		"echo \"sudo $*\" >> \"$STUB_LOG\"\n" +
		"[ \"$1\" = \"-n\" ] && shift\n" +
		"if [ -n \"${STUB_GUARD_SEVER:-}\" ] && [ \"$1\" = mv ]; then\n" +
		"    case \"$3\" in\n" +
		"    */.phase.tmp)\n" +
		"        if [ \"$(cat \"$3\" 2>/dev/null)\" = handoff ]; then\n" +
		"            \"$@\"\n" +
		"            _sev_txn=\"$(dirname \"$4\")\"\n" +
		"            kill -9 \"$(cat \"$_sev_txn/installer.pid\" 2>/dev/null)\" 2>/dev/null\n" +
		"            exit 0\n" +
		"        fi\n" +
		"        ;;\n" +
		"    esac\n" +
		"fi\n" +
		"exec \"$@\"\n"
	if err := os.WriteFile(filepath.Join(dir, "sudo"), []byte(content), 0o755); err != nil {
		t.Fatalf("write stub sudo: %v", err)
	}
}

// installShEnv is the base environment for running install.sh in a sandbox:
// HOME/PATH plus the system-unit dir seams, the $BIN_DIR redirect, and the
// stub call log.
//
// BURROWEE_BIN_DIR, and NEVER PREFIX: install.sh refuses outright when PREFIX
// is set, so a fixture that set it would not be exercising a different install
// flow — it would be exercising the refusal, in every test at once. The redirect
// is the seam that keeps the real /usr/local/bin untouched without changing what
// the install means (bin_dir_default_test.go pins both halves of that).
//
// Note the environment handed to install.sh is built from this list ALONE, not
// inherited: a PREFIX exported in the developer's own shell would otherwise
// reach the script and turn this whole package red.
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
		"BURROWEE_LIBEXEC_DIR=" + libexecDir(home),
		"BURROWEE_LEGACY_BIN_DIR=" + legacyBinDir(home),
		// REATTACH_CEILING=0 (Task 9): the fresh-install path now ends by
		// polling the transaction's phase file for the guard's verdict
		// (install.sh's reattach). This suite's systemd-run/launchctl stubs
		// only RECORD the arm call (stubInitSystem's own header explains why:
		// a real systemd-run would hand a live transient unit to the HOST's
		// own systemd, which every other stub here exists to prevent) — no
		// guard process ever actually runs here, so the phase file never
		// reaches a terminal state on its own. Left at its production
		// default (180s, polled every 2s) every fresh-install test in this
		// package would block for up to three minutes apiece; ceiling 0 skips
		// the wait loop outright (reattach's own `_waited -lt 0` is false on
		// the first check) and takes the "guard has not reported yet" branch
		// immediately, which is the correct, honest outcome for a harness
		// that never arms a real guard.
		"REATTACH_CEILING=0",
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

// latestTxnPhase reads the phase file of the transaction install.sh most
// recently created under sysDataDir(home)/install/ — txn_begin's own
// destination — and returns its content, trimmed.
//
// Transaction directories are named by a UTC timestamp (txn_begin's
// TXN_STAMP), which sorts lexically, so the LAST entry is the most recent —
// there is at most one per runInstallSh/runStaged call in this suite, but
// "most recent" is still the honest selection rather than "the only one",
// since a test may legitimately run install.sh more than once against the
// same home.
// latestTxnDir is the newest install transaction directory under home's system
// data root. Stamps are UTC and fixed-width, and os.ReadDir returns entries
// sorted by filename, so the last entry is the newest.
func latestTxnDir(t *testing.T, home string) string {
	t.Helper()
	root := filepath.Join(sysDataDir(home), "install")
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("read transaction root %s: %v", root, err)
	}
	if len(entries) == 0 {
		t.Fatalf("no transaction directory under %s — txn_begin never ran", root)
	}
	return filepath.Join(root, entries[len(entries)-1].Name())
}

func latestTxnPhase(t *testing.T, home string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(latestTxnDir(t, home), "phase"))
	if err != nil {
		t.Fatalf("read phase file for the newest transaction: %v", err)
	}
	return strings.TrimSpace(string(b))
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

// TestFreshInstallAlsoLeavesTheDataRootPrivate is TestInstallShCreatesSystemLogDir's
// missing sibling, and it is missing in the direction that matters.
//
// The 0700 rule for $SYS_DATA_DIR — it holds gateway.db and the register and
// console sockets, so a permissive umask must never leave it group-readable —
// was only ever asserted on the units-only path. The rule itself lives in
// ensure_system_log_dir and applies only when THAT function created the root,
// which was true until the install transaction moved ahead of it: txn_begin's
// `mkdir -p $SYS_DATA_DIR/install/<stamp>` creates the root as a side effect,
// with the caller's umask, and ensure_system_log_dir then finds it already
// there and correctly declines to re-tighten a root it did not create.
//
// That made every guarded install leave a 0775 data root on a host with a
// permissive umask — on BOTH paths, and only one of them had a test. This is
// the other one, so a future rearrangement of the same kind fails on the fresh
// install rather than being caught by units-only alone (or by nothing, if the
// units-only assertion is ever the one that moves).
func TestFreshInstallAlsoLeavesTheDataRootPrivate(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)

	if out, err := runStaged(t, installShPath(t), staging, home, stub); err != nil {
		t.Fatalf("fresh install failed: %v\n%s", err, out)
	}

	di, err := os.Stat(sysDataDir(home))
	if err != nil {
		t.Fatalf("stat system data root: %v", err)
	}
	if perm := di.Mode().Perm(); perm != 0o700 {
		t.Errorf("system data root mode = %04o, want 0700 — it holds gateway.db and the register/console sockets, and the transaction directory created it with the caller's umask", perm)
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

	// The kept self-copy is the ROOT-OWNED one, and it is the only one. A copy
	// under the operator's home is the defect this installer stopped shipping.
	if _, err := os.Stat(filepath.Join(binDir, "install.sh")); err != nil {
		t.Errorf("self-copy missing at $BIN_DIR/install.sh: %v", err)
	}
	if _, err := os.Stat(filepath.Join(home, ".burrowee")); err == nil {
		t.Errorf("the installer created %s — nothing it does belongs in the operator's home", filepath.Join(home, ".burrowee"))
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

// TestInstallShNoRestartStagesWithoutArming verifies BURROWEE_NO_RESTART=1 —
// the local-stage counterpart to the gateway's `update`/`reinstall` verbs
// without --auto — on the units-only path, where the flag's meaning changed
// because the path it modifies did.
//
// IT USED TO MEAN "STAGED, NOT KICKED", AND THAT WAS A WEAKER PROMISE THAN THE
// FLAG MAKES. The old shape went through load_units' staging branch: a Darwin
// `bootstrap` of each label and a Linux `enable` without `--now`, skipping only
// the kick of an already-running instance. But the serve plist this installer
// writes is RunAtLoad, so a bootstrap of a label the host does not already hold
// STARTS the daemon. An operator who set this flag because a start was
// unacceptable got one anyway, on exactly the fresh host where the flag is most
// likely to be set.
//
// It now means what it says, and the same thing it means on the fresh path
// (guard_arm's own header): no guard is armed, nothing is handed off, the units
// are rendered on disk and NOT loaded. That is a strictly larger claim than the
// old one, so this test asserts the larger one — no supervisor call touching
// either managed unit, from any verb.
//
// Both platform branches run on every host: the flag is read in one place
// (guard_arm), but "which supervisor calls did NOT happen" is answerable only
// per platform, and a platform whose branch is never driven is a platform whose
// branch is never checked.
func TestInstallShNoRestartStagesWithoutArming(t *testing.T) {
	for _, goos := range forcedOSes {
		t.Run(goos, func(t *testing.T) { testInstallShNoRestartStagesWithoutArming(t, goos) })
	}
}

func testInstallShNoRestartStagesWithoutArming(t *testing.T, goos string) {
	home := t.TempDir()
	stub := stubInitSystemFor(t, goos)
	seedMigrateCapableCLI(t, home)

	out := runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1", "BURROWEE_NO_RESTART=1")
	assertContains(t, out,
		"BURROWEE_NO_RESTART set — the install guard is NOT armed",
		"units staged on disk. Nothing was restarted (BURROWEE_NO_RESTART).",
	)

	// The durable outcome the flag DOES promise: both unit files written.
	// Without this the assertions below pass on a run that did nothing at all.
	for _, u := range unitPathsFor(home, goos) {
		if _, err := os.Stat(u); err != nil {
			t.Fatalf("BURROWEE_NO_RESTART=1: %s was not rendered — the flag stages units, it does not skip writing them: %v", u, err)
		}
	}

	calls := readFile(t, filepath.Join(home, "stub-calls.log"))
	// No guard, and therefore no handoff and no restart by anybody. This is the
	// assertion the old shape could not make: it armed and handed off, and the
	// guard restarted the daemon on a run whose whole point was that nothing
	// should start.
	if strings.Contains(calls, guardArmCallFor(goos)) {
		t.Errorf("BURROWEE_NO_RESTART=1 armed a guard (%q) — the guard restarts the gateway, which is the one thing this flag asks not to happen:\n%s",
			guardArmCallFor(goos), calls)
	}
	if dir := latestTxnDirOrEmpty(t, home); dir != "" {
		if b, err := os.ReadFile(filepath.Join(dir, "phase")); err == nil {
			if got := strings.TrimSpace(string(b)); got == "handoff" {
				t.Errorf("BURROWEE_NO_RESTART=1 reached phase %q — a handoff is a restart request", got)
			}
		}
	}

	// And nothing loaded either managed unit. "bootout gui/…" is
	// remove_legacy_user_units tearing down the pre-system-level per-user units,
	// and "systemctl --user …" is its Linux half: both are teardown of the OLD
	// model, not a start of the new one, and both must still fire.
	for _, line := range strings.Split(calls, "\n") {
		c := strings.TrimSpace(line)
		if c == "" || strings.Contains(c, "gui/") || strings.Contains(c, "--user") {
			continue
		}
		if !strings.Contains(c, "com.burrowee.gateway") && !strings.Contains(c, "burrowee-gateway") {
			continue
		}
		if strings.Contains(c, ".guard") {
			continue // asserted absent above; a match here would be that failure twice
		}
		switch {
		case strings.Contains(c, "bootstrap"), strings.Contains(c, "kickstart"),
			strings.Contains(c, "enable"), strings.Contains(c, "restart"),
			strings.Contains(c, "start "), strings.Contains(c, "bootout"):
			t.Errorf("BURROWEE_NO_RESTART=1: %q touched a managed unit — on Darwin a bootstrap of the RunAtLoad serve plist STARTS the daemon, which is what this flag exists to prevent:\n%s", c, calls)
		}
	}
}

// unitPathsFor is the pair of system unit files install.sh renders on goos.
func unitPathsFor(home, goos string) []string {
	if goos == "darwin" {
		return []string{
			filepath.Join(launchdDir(home), "com.burrowee.gateway.plist"),
			filepath.Join(launchdDir(home), "com.burrowee.gateway.updater.plist"),
		}
	}
	return []string{
		filepath.Join(systemdDir(home), "burrowee-gateway.service"),
		filepath.Join(systemdDir(home), "burrowee-gateway-updater.service"),
	}
}

// latestTxnDirOrEmpty is latestTxnDir for a run that may legitimately have made
// no transaction at all — which under BURROWEE_NO_RESTART it still does make
// (guard_arm's header: the transaction and the snapshot are taken either way,
// they are what guard-status reads afterwards), so this is tolerance for the
// shape rather than an expectation about it.
func latestTxnDirOrEmpty(t *testing.T, home string) string {
	t.Helper()
	root := filepath.Join(sysDataDir(home), "install")
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) == 0 {
		return ""
	}
	return filepath.Join(root, entries[len(entries)-1].Name())
}

// TestInstallShUnitsOnlyTouchesNeitherManagedLabel is what is left of
// TestInstallShDefaultPathDoesNotFlapUnits once the calls it counted stopped
// being made in this process.
//
// That test pinned the flap: each label bootstrapped exactly once, the serve
// label advanced with `kickstart -k` and never booted out (an unloaded job is
// supervised by nothing, and on a gateway the bootout is what kills the shell
// that would have bootstrapped it again), the updater booted out BEFORE it was
// bootstrapped rather than after. It drove BURROWEE_UNITS_ONLY because that was
// the last mode still loading units synchronously.
//
// It is not any more, and this suite cannot follow the calls where they went:
// stubInitSystem's launchctl RECORDS the arm and never spawns the guard behind
// it (its own header explains why), so the guard's bootstrap/kickstart/bootout
// sequence happens in no process this test can observe. The whole claim, per
// platform shape, against the real guard.sh and a real (fake) supervisor, is
// tools/guard-rollback.test.sh's t_guard_does_not_flap_the_units — written for
// this change specifically so nothing was dropped in the move.
//
// WHAT REMAINS HERE IS THE HALF THAT IS STILL THIS FILE'S, and it is the half
// that protects the move: install.sh's own foreground must touch NEITHER
// managed label. A regression that re-adds a load_units call to this mode
// would restore the flap AND the sever, and it would show up here first.
func TestInstallShUnitsOnlyTouchesNeitherManagedLabel(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("launchctl call shapes are Darwin-only; the Linux half is TestLinuxUnitsOnlyIssuesNoRestartOfItsOwn")
	}
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")
	calls := readFile(t, filepath.Join(home, "stub-calls.log"))

	// The sudo stub records its own "sudo -n launchctl …" line and then execs
	// launchctl, which records "launchctl …" — so every real call appears on
	// two lines. Match whole lines against the bare form to count each once.
	for _, line := range strings.Split(calls, "\n") {
		c := strings.TrimSpace(line)
		if !strings.HasPrefix(c, "launchctl ") {
			continue
		}
		// The GUARD's own label is install.sh's to drive — that IS the handoff,
		// and guard_arm boots it out first deliberately (nothing routes through
		// it, and guard_refuse_concurrent has already proved no live guard is
		// mid-flight). Legacy per-user teardown ("gui/…") stays too.
		if strings.Contains(c, "com.burrowee.gateway.guard") || strings.Contains(c, "gui/") {
			continue
		}
		if strings.Contains(c, "com.burrowee.gateway") {
			t.Errorf("units-only drove %q against a managed label in install.sh's own foreground — the restart belongs to the guard, and a foreground one severs the connection the operator is running this over:\n%s", c, calls)
		}
	}

	// Not vacuous: the run really did reach the handoff, so "no managed-label
	// call" is a fact about a completed install and not about one that fell
	// over before it got there.
	if got := latestTxnPhase(t, home); got != "handoff" {
		t.Fatalf("transaction phase = %q, want %q — this run never reached the point the assertions above are about", got, "handoff")
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

	// The install guard, placed on the root-secure surface beside install.sh
	// and migrations/ because launchd/systemd exec it AS ROOT. An uninstall
	// that leaves it hands the next install a root-owned script nothing
	// re-verified, on a host that no longer has a gateway.
	if p := filepath.Join(binDir, "guard.sh"); func() bool { _, err := os.Stat(p); return err == nil }() {
		t.Errorf("the install guard is still present after uninstall: %s", p)
	}

	// System unit files removed — the GUARD's plist among them. It is
	// RunAtLoad, so one left behind re-execs the guard against a stale
	// transaction directory at every boot, on a host with no gateway at all.
	// guard.sh removes it itself on every exit path; this is the belt to that
	// braces, for a guard that was SIGKILLed or could not write the directory.
	if runtime.GOOS == "darwin" {
		for _, name := range []string{
			"com.burrowee.gateway.plist",
			"com.burrowee.gateway.updater.plist",
			"com.burrowee.gateway.guard.plist",
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

// stageInstaller copies the real install.sh (and the real guard.sh beside
// it — the same real release payload shape payload.test.sh pins) into dir,
// so a test can plant a fake migrations/ beside both. install.sh resolves
// the migration, and guard_arm resolves the guard, relative to install.sh's
// OWN path (not cwd — `service install` re-runs the kept copy from an
// arbitrary working directory), so all of these have to sit together.
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
	guardBody, err := os.ReadFile(guardShPath(t))
	if err != nil {
		t.Fatalf("read guard.sh: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "guard.sh"), guardBody, 0o755); err != nil {
		t.Fatalf("stage guard.sh: %v", err)
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

// TestInstallShRunsTheMigrationBeforeTheHandoff.
//
// The migration stops the daemon (gateway's own migrations/run.sh) and the
// handoff is where the guard is told to start it again, so the migration has to
// be finished before the handoff is written. Any other order and the guard
// restarts a gateway whose state is still being copied out from under it.
//
// THE OLD SHAPE OF THIS TEST DID NOT ACTUALLY CHECK AN ORDER. It computed
// `ran` (an index into stdout) and `started` (an index into the stub call log)
// and then only asserted each was >= 0 — two positions in two different
// streams, which cannot be compared even in principle, and the comparison was
// never written. So it passed on any run where the migration ran and the
// supervisor was called at all, in either order. It would go on passing now,
// vacuously, off remove_legacy_user_units' own `systemctl --user` line.
//
// Both anchors are in ONE stream here — install.sh's own output — which is what
// makes the ordering answerable: the staged migration prints "migration-ran",
// and the handoff prints its reconnect banner immediately before txn_phase
// handoff (deliberately before, so the line reaches the operator while the
// connection still exists).
func TestInstallShRunsTheMigrationBeforeTheHandoff(t *testing.T) {
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
	handoff := strings.Index(out, "handing the restart to the guard")
	if ran < 0 {
		t.Fatalf("migration output missing:\n%s", out)
	}
	if handoff < 0 {
		t.Fatalf("the restart was never handed to the guard, so nothing was ordered against it:\n%s", out)
	}
	if ran > handoff {
		t.Errorf("the migration ran AFTER the handoff — the guard restarts the gateway while its state is still being copied:\n%s", out)
	}
	if got := latestTxnPhase(t, home); got != "handoff" {
		t.Errorf("transaction phase = %q, want %q", got, "handoff")
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
