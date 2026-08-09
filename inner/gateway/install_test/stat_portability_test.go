// stat_portability_test.go — the GNU/BSD `stat` divergence, and the reason this
// file exists at all.
//
// install.sh's root-secure predicate read a file's owner and mode with
// `stat -f FMT … || stat -c FMT …`: the BSD spelling first, the GNU spelling as
// the fallback. That is correct on macOS and catastrophic on Linux, because on
// GNU coreutils `-f` is `--file-system`. `stat -f '%u' PATH` there does not fail
// cleanly — it reads '%u' as a SECOND PATH, prints PATH's filesystem geometry to
// STDOUT, complains about '%u' on stderr, and exits 1. The `||` fallback then
// appends the real answer, so the caller received a four-line blob ENDING in the
// correct uid, `[ "$(stat_uid p)" = 0 ]` was false, and every Linux host was told
// its correctly-installed root tree was insecure.
//
// It shipped because the surrounding suite runs on macOS, where the first branch
// always wins and the second is dead code. A test that only ever exercises one
// side of a platform divergence cannot see the divergence — so these tests do not
// depend on the host's own stat at all. They put a stat of a KNOWN dialect on
// PATH and drive the real install.sh against it, which makes the Linux behaviour
// reproducible from this macOS machine and from any other.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

// statStubGNU emulates GNU coreutils stat for the two call shapes install.sh
// uses, INCLUDING the `-f` misfire that caused the outage: every remaining word
// is treated as a path to a filesystem, the caller's format string among them.
//
// It reports uid 0 / mode 755 for every path that exists, so the fixture it is
// pointed at looks like a correctly-installed root-owned tree — the exact state
// the affected node was in while being refused.
const statStubGNU = `#!/bin/sh
case "${1:-}" in
-c)
    _fmt="$2"
    shift 2
    for _p in "$@"; do
        if [ ! -e "$_p" ]; then
            echo "stat: cannot statx '$_p': No such file or directory" >&2
            exit 1
        fi
        case "$_fmt" in
        '%u') echo 0 ;;
        '%a') echo 755 ;;
        *) echo "stat: invalid directive: $_fmt" >&2; exit 1 ;;
        esac
    done
    ;;
-f)
    shift
    _rc=0
    for _p in "$@"; do
        if [ -e "$_p" ]; then
            echo "  File: \"$_p\""
            echo "    ID: 26b9871bc77c8277 Namelen: 255     Type: ext2/ext3"
            echo "Block size: 4096       Fundamental block size: 4096"
        else
            echo "stat: cannot read file system information for '$_p': No such file or directory" >&2
            _rc=1
        fi
    done
    exit $_rc
    ;;
*)
    echo "stat: unrecognized option '${1:-}'" >&2
    exit 1
    ;;
esac
`

// statStubBSD emulates macOS /usr/bin/stat, and its default arm is the half of
// the fix that would otherwise be an assumption: an unknown flag produces a
// usage error on STDERR, NOTHING on stdout, and exit 1. install.sh's dialect
// probe tries the GNU spelling first and relies on precisely that — a BSD stat
// that leaked anything to stdout there would poison the probe.
//
// The arm is transcribed from the real thing, verified on this host:
//
//	$ /usr/bin/stat -c '%u' /
//	/usr/bin/stat: illegal option -- c
//	usage: stat [-FLnq] [-f format | -l | -r | -s | -x] [-t timefmt] [file ...]
//	stdout empty, exit 1
const statStubBSD = `#!/bin/sh
case "${1:-}" in
-f)
    _fmt="$2"
    shift 2
    for _p in "$@"; do
        if [ ! -e "$_p" ]; then
            echo "stat: $_p: stat: No such file or directory" >&2
            exit 1
        fi
        case "$_fmt" in
        '%u') echo 0 ;;
        '%Lp') echo 755 ;;
        *) echo "stat: invalid format" >&2; exit 1 ;;
        esac
    done
    ;;
*)
    echo "stat: illegal option -- ${1#-}" >&2
    echo "usage: stat [-FLnq] [-f format | -l | -r | -s | -x] [-t timefmt] [file ...]" >&2
    exit 1
    ;;
esac
`

// statStubJunk is a stat that SUCCEEDS while answering with something that is
// not a value: a multi-line blob whose last line is a perfectly plausible "0".
//
// It answers cleanly for "/" alone, so install.sh's dialect probe still resolves
// — the point under test is not the probe but the contract that a helper hands
// back one clean value or nothing. A helper that forwards whatever stat printed
// turns this into `[ "<blob>" = 0 ]`, a silent false, and an operator sent to
// audit permissions that were never the problem.
const statStubJunk = `#!/bin/sh
_last=""
for _a in "$@"; do _last="$_a"; done
if [ "$_last" = "/" ]; then echo 0; exit 0; fi
echo "  File: \"$_last\""
echo "    ID: 26b9871bc77c8277 Namelen: 255     Type: ext2/ext3"
echo 0
exit 0
`

type statDialect struct {
	name string
	body string
}

// realisticStatDialects are the two dialects a real host can speak. Every
// behavioural test runs against BOTH, because passing on one is what shipped.
var realisticStatDialects = []statDialect{
	{"gnu", statStubGNU},
	{"bsd", statStubBSD},
}

// writeStatStub drops a stat of a chosen dialect into the stub dir, which the
// harness puts first on PATH. install.sh invokes `stat` unqualified, so this is
// the stat it gets.
func writeStatStub(t *testing.T, dir, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, "stat"), []byte(body), 0o755); err != nil {
		t.Fatalf("write stat stub: %v", err)
	}
}

// shellsUnderTest is every POSIX shell available here that install.sh must run
// under. `sh` is what the outer bootstrap execs; dash is the far stricter one
// that /bin/sh actually IS on Debian and Ubuntu — which is where these hosts
// live, and so the only shell whose acceptance means anything for them.
func shellsUnderTest(t *testing.T) []string {
	t.Helper()
	shells := []string{"sh"}
	for _, cand := range []string{"/bin/dash", "/usr/bin/dash"} {
		if _, err := os.Stat(cand); err == nil {
			shells = append(shells, cand)
			break
		}
	}
	if len(shells) == 1 {
		t.Log("note: no dash on this host — install.sh exercised under /bin/sh only")
	}
	return shells
}

// runInstallShUnder runs install.sh with an explicit shell, returning combined
// output and the exit error. The package's other runners hardcode `sh`; these
// tests need to vary it.
func runInstallShUnder(t *testing.T, shell, home, stubDir string, extraEnv ...string) (string, error) {
	t.Helper()
	cmd := exec.Command(shell, installShPath(t))
	cmd.Dir = home
	cmd.Env = installShEnv(home, stubDir, extraEnv...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// seedNodeShapedHost builds the fixture the affected node presented: an
// already-enrolled 0.2.x host whose identity has moved to the SYSTEM config
// root and whose per-user binaries (seedMigrateCapableCLI, at $BIN_DIR) are
// all present — the ownership walk under test is run against exactly that
// content, re-verified in place rather than placed fresh (see
// TestInstallShPlacesTheRootExecedBinariesInBinDir's comment for why there is
// no longer a separate, initially-empty privileged tree to assert against).
func seedNodeShapedHost(t *testing.T, home string) {
	t.Helper()
	seedMigrateCapableCLI(t, home)
	identity := filepath.Join(sysConfigDir(home), "identity")
	if err := os.MkdirAll(identity, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(identity, "relay_ed.key"), []byte("fixture-key\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// serviceStartCall is the stub-log line that proves the unit was not merely
// written but handed to the init system to run.
func serviceStartCall() string {
	if runtime.GOOS == "darwin" {
		return "launchctl bootstrap system"
	}
	return "systemctl enable --now burrowee-gateway.service"
}

// TestInstallShConvergesANodeShapedHostUnderEitherStatDialect is the acceptance
// test for the whole install contract, run once per stat dialect and once per
// shell: place the binaries in the correct folder, render the unit naming that
// folder, and start the service.
//
// Under the `bsd` dialect it passed before this change and passes after — that
// is the control. Under `gnu` it is the outage, reproduced: the tree is placed
// and is genuinely root-owned (the stub says uid 0 / 755 for everything, which
// is what the node really was), and the pre-fix predicate still refused, so
// install.sh aborted with "not root-owned" before writing a unit.
func TestInstallShConvergesANodeShapedHostUnderEitherStatDialect(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: the harness's uid-0 simulation is meaningless and the fixture would be really root-owned")
	}
	for _, dialect := range realisticStatDialects {
		for _, shell := range shellsUnderTest(t) {
			t.Run(dialect.name+"/"+filepath.Base(shell), func(t *testing.T) {
				home := t.TempDir()
				stub := stubInitSystem(t)
				seedNodeShapedHost(t, home)
				fakeRootUID(t, stub)
				writeStatStub(t, stub, dialect.body)

				out, err := runInstallShUnder(t, shell, home, stub, "BURROWEE_UNITS_ONLY=1")
				if err != nil {
					t.Fatalf("install.sh refused a host whose privileged tree is root-owned (%v):\n%s", err, out)
				}
				// Without this the whole test can pass vacuously: install.sh
				// skips the ownership walk entirely when its elevation path
				// never reached uid 0, and a skipped check refuses nothing.
				if strings.Contains(out, "never reached uid 0") {
					t.Fatalf("the root-secure check was skipped, so this proves nothing:\n%s", out)
				}

				// 1. binaries in the correct folder
				for _, name := range append(rootExecedBins, "install.sh") {
					if _, err := os.Stat(filepath.Join(binDir(home), name)); err != nil {
						t.Errorf("%s was not placed in $BIN_DIR: %v", name, err)
					}
				}
				// 2. the unit names $BIN_DIR
				unit := readFile(t, coreUnitPath(home))
				assertContains(t, unit, filepath.Join(binDir(home), "burrowee-gateway"))
				// 3. the service was handed to the init system
				assertContains(t, readFile(t, filepath.Join(home, "stub-calls.log")), serviceStartCall())
			})
		}
	}
}

// TestInstallShRefusesAndBlamesStatWhenTheModeCannotBeRead is the failure mode,
// and it is about the MESSAGE as much as the refusal.
//
// Guarding a root exec means refusing whenever the path cannot be proved safe,
// including when it could not be inspected — that part is not negotiable. But
// "your tree is writable by a non-root user" and "I could not read your tree"
// send an operator to two unrelated places, and answering the first when the
// second is true is what cost hours on the affected node: the tree was
// root:root 755 the entire time it was being told it was not.
func TestInstallShRefusesAndBlamesStatWhenTheModeCannotBeRead(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: the harness's uid-0 simulation is meaningless")
	}
	for _, shell := range shellsUnderTest(t) {
		t.Run(filepath.Base(shell), func(t *testing.T) {
			home := t.TempDir()
			stub := stubInitSystem(t)
			seedNodeShapedHost(t, home)
			fakeRootUID(t, stub)
			writeStatStub(t, stub, statStubJunk)

			out, err := runInstallShUnder(t, shell, home, stub, "BURROWEE_UNITS_ONLY=1")
			if err == nil {
				t.Fatalf("install.sh accepted a tree whose ownership it never actually read:\n%s", out)
			}
			assertContains(t, out, "could not read the owner and mode")
			// The wrong diagnosis, specifically. Its presence means the operator
			// is being sent to audit permissions again.
			assertNotContains(t, out, "not root-owned and unwritable")
			if _, err := os.Stat(coreUnitPath(home)); err == nil {
				t.Errorf("a unit was written naming a tree that was never verified: %s", coreUnitPath(home))
			}
		})
	}
}

// statHelperPrelude returns install.sh truncated immediately after stat_mode —
// the dialect probe and the three helpers, with none of the mode dispatch — so a
// test can call them directly.
//
// The extraction is checked rather than trusted: a refactor that moves or renames
// the helpers fails this loudly instead of leaving a test that evaluates the
// wrong text and passes for no reason.
func statHelperPrelude(t *testing.T) string {
	t.Helper()
	body, err := os.ReadFile(installShPath(t))
	if err != nil {
		t.Fatalf("read install.sh: %v", err)
	}
	lines := strings.Split(string(body), "\n")
	end := -1
	for i, l := range lines {
		if l == "stat_mode() {" {
			for j := i + 1; j < len(lines); j++ {
				if lines[j] == "}" {
					end = j
					break
				}
			}
			break
		}
	}
	if end < 0 {
		t.Fatal("could not find stat_mode() in install.sh — this test is extracting the wrong text")
	}
	prelude := strings.Join(lines[:end+1], "\n")
	for _, want := range []string{"is_digits() {", "STAT_FLAVOR=", "stat_field() {", "stat_uid() {"} {
		if !strings.Contains(prelude, want) {
			t.Fatalf("extracted prelude is missing %q — the helpers moved and this test no longer covers them", want)
		}
	}
	return prelude
}

var oneLineOfDigits = regexp.MustCompile(`^[0-9]+$`)

// TestStatHelpersEmitExactlyOneLineOfDigits asserts the OUTPUT SHAPE, which is
// the platform-independent half of this fix.
//
// Whatever a host's stat says, `stat_uid` and `stat_mode` either print a single
// line of digits or print nothing — there is no third answer for a caller to
// compare against by accident. A shape assertion cannot tell you the value is
// right, but it would have caught the shipped bug on its own: the answer that
// stranded the node was four lines long.
func TestStatHelpersEmitExactlyOneLineOfDigits(t *testing.T) {
	prelude := statHelperPrelude(t)
	probe := prelude + `
printf 'UID_LINES=%s\n'  "$(stat_uid  / | wc -l | tr -d ' ')"
printf 'UID_VALUE=%s\n'  "$(stat_uid  /)"
printf 'MODE_LINES=%s\n' "$(stat_mode / | wc -l | tr -d ' ')"
printf 'MODE_VALUE=%s\n' "$(stat_mode /)"
`
	for _, dialect := range realisticStatDialects {
		for _, shell := range shellsUnderTest(t) {
			t.Run(dialect.name+"/"+filepath.Base(shell), func(t *testing.T) {
				home := t.TempDir()
				stub := t.TempDir()
				writeStatStub(t, stub, dialect.body)

				cmd := exec.Command(shell, "-c", probe)
				cmd.Dir = home
				cmd.Env = []string{"HOME=" + home, "PATH=" + stub + ":/usr/bin:/bin"}
				out, err := cmd.CombinedOutput()
				if err != nil {
					t.Fatalf("probe failed: %v\n%s", err, out)
				}

				got := map[string]string{}
				for _, l := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
					if k, v, ok := strings.Cut(l, "="); ok {
						got[k] = v
					}
				}
				for _, field := range []string{"UID", "MODE"} {
					if got[field+"_LINES"] != "1" {
						t.Errorf("stat_%s printed %s lines, want exactly 1 — a multi-line answer is what the caller silently compares against 0",
							strings.ToLower(field), got[field+"_LINES"])
					}
					if !oneLineOfDigits.MatchString(got[field+"_VALUE"]) {
						t.Errorf("stat_%s printed %q, want digits only", strings.ToLower(field), got[field+"_VALUE"])
					}
				}
			})
		}
	}
}
