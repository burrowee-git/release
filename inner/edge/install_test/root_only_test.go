// root_only_test.go — the collapse: ONE destination (/usr/local/bin, root-owned),
// one privilege level (root), and the two refusals that keep it that way.
//
// The literal destination is checked as SOURCE TEXT, never by running the
// installer with it: it is a real system path, and the machines this suite runs
// on have a live burrowee in it. Every dynamic test here redirects it with the
// SYS_BIN_DIR seam into a fixture tree. The REFUSALS are the opposite — "a
// PREFIX naming anywhere else is rejected" and "an unprivileged run is
// rejected" are claims about
// behaviour at a moment (before anything is placed), so they have to be run, and
// run under every shell a host's /bin/sh may be.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// wantBinDirDefault is the destination a production edge host resolves. The
// gateway's sibling pin (inner/gateway/install_test/bin_dir_default_test.go)
// names the same directory; they moved together and must keep moving together —
// the dispatcher resolves both components there by absolute path.
const wantBinDirDefault = "/usr/local/burrowee/bin"

// collapseVersion is the release this collapse ships in, as the refusals name it
// to the operator. Pinned here so the two messages and this expectation cannot
// drift apart silently; if the collapse is cut under a different number, this
// constant and install.sh's strings move in the same change.
const collapseVersion = "edge 0.2.0"

// shellsUnderTest is every POSIX shell available here that install.sh must run
// under. `sh` is whatever the host's /bin/sh is — bash 3.2 on macOS, dash on
// Debian-family — and dash and bash are named explicitly so a run on either
// platform still exercises BOTH dialects when they are installed. Missing
// shells are skipped with a note rather than failing: not every host has both.
// Mirrors the gateway suite's helper of the same name.
//
// This is not decoration. The /dev/tty defect that shipped in this exact file
// was invisible to a suite that only ran `sh` on macOS, because there `sh` is
// bash and the bug is dash-only.
func shellsUnderTest(t *testing.T) []string {
	t.Helper()
	shells := []string{"sh"}
	for _, alt := range [][]string{
		{"/bin/dash", "/usr/bin/dash"},
		{"/bin/bash", "/usr/bin/bash", "/usr/local/bin/bash"},
	} {
		found := ""
		for _, cand := range alt {
			if _, err := os.Stat(cand); err == nil {
				found = cand
				break
			}
		}
		if found == "" {
			t.Logf("note: %v not on this host — not exercised", alt)
			continue
		}
		shells = append(shells, found)
	}
	return shells
}

// sandbox is one fixture host: a $HOME, the sandboxed system paths install.sh
// writes to, and the staging dir it installs FROM.
type sandbox struct {
	home      string
	staging   string
	sysBinDir string
	unitDir   string
	rootHome  string
	// The two machine-owned parents, redirected into the sandbox. Without
	// these every run below would try to create the REAL
	// /usr/local/{etc,var}/burrowee — which on this runner is somebody else's
	// gateway install, and on a developer's machine is a root-owned path a
	// test has no business touching.
	sysConfigRoot string
	sysDataRoot   string
}

// compHome / compData are the two roots install.sh resolves inside this
// sandbox.
func (sb sandbox) compHome() string { return filepath.Join(sb.sysConfigRoot, "edge") }
func (sb sandbox) compData() string { return filepath.Join(sb.sysDataRoot, "edge") }

// newSandbox lays out a fixture host with the edge binaries staged. Nothing
// here resolves outside t.TempDir().
func newSandbox(t *testing.T) sandbox {
	t.Helper()
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	// Every real edge kit carries migrations/ since the ladder shipped, and the
	// stale-bin sweep now lives inside it — a sandbox without it would be
	// exercising a bundle shape no host receives.
	stageMigrations(t, staging)
	sb := sandbox{
		home:          home,
		staging:       staging,
		sysBinDir:     filepath.Join(home, "sysbin"),
		unitDir:       filepath.Join(home, "systemd-system"),
		rootHome:      filepath.Join(home, "root-home"),
		sysConfigRoot: filepath.Join(home, "sys-etc", "burrowee"),
		sysDataRoot:   filepath.Join(home, "sys-var", "burrowee"),
	}
	if err := os.MkdirAll(sb.unitDir, 0o755); err != nil {
		t.Fatalf("mkdir unitDir: %v", err)
	}
	return sb
}

// env is the environment every run in this file uses: the system paths
// redirected into the sandbox, including the LaunchDaemons dir that
// unit_naming_dir would otherwise scan for real on a macOS host.
func (sb sandbox) env(stub string, extra ...string) []string {
	e := []string{
		"HOME=" + sb.home,
		"PATH=" + stub + ":/usr/bin:/bin",
		"STUB_LOG=" + filepath.Join(sb.home, "stub-calls.log"),
		"SYS_BIN_DIR=" + sb.sysBinDir,
		"BURROWEE_LEGACY_BIN_DIR=" + filepath.Join(sb.home, "usr-local-bin"),
		"SYSTEMD_UNIT_DIR=" + sb.unitDir,
		"LAUNCHD_PLIST_DIR=" + filepath.Join(sb.home, "LaunchDaemons"),
		"ROOT_HOME=" + sb.rootHome,
		"SYS_CONFIG_ROOT=" + sb.sysConfigRoot,
		"SYS_DATA_ROOT=" + sb.sysDataRoot,
	}
	return append(e, extra...)
}

// run executes install.sh under the named shell with the given stub PATH dir,
// returning combined output and the process error (nil ⇒ exit 0).
func (sb sandbox) run(t *testing.T, shell, stub string, extra ...string) (string, error) {
	t.Helper()
	cmd := exec.Command(shell, stagedInstaller(t, sb.staging))
	cmd.Dir = sb.staging
	cmd.Env = sb.env(stub, extra...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// assertNothingPlaced is the half of a refusal that is not the exit status: a
// check that fires after a half-install is not a refusal. It looks in BOTH
// candidate directories — the system one this installer would use, and the
// per-user one the operator asked for.
func (sb sandbox) assertNothingPlaced(t *testing.T, out string) {
	t.Helper()
	for _, dir := range []string{sb.sysBinDir, filepath.Join(sb.home, ".local", "bin")} {
		for _, b := range edgeBins {
			if _, err := os.Stat(filepath.Join(dir, b)); err == nil {
				t.Errorf("%s was placed in %s despite the refusal — the check ran too late to matter\n%s", b, dir, out)
			}
		}
	}
	for _, unit := range []string{"burrowee-edge.service", "burrowee-edge-updater.service"} {
		if _, err := os.Stat(filepath.Join(sb.unitDir, unit)); err == nil {
			t.Errorf("%s was rendered despite the refusal\n%s", unit, out)
		}
	}
}

// TestEdgeInstallShDestinationIsTheOneSystemBinDir pins the destination as
// source text, and pins the per-user branch as GONE rather than merely
// unreachable.
//
// The banned strings are the branch coming back in the two shapes it had: a
// $PREFIX-derived $BIN_DIR, and the `if is_root` fork that decided which one to
// take. While that fork existed it also gated setup_root_service, the unit
// teardown on uninstall, the stale-bin sweep and the version marker's location —
// so one reintroduced branch switches off the whole privileged surface again
// while every binary still lands somewhere, which is exactly what made the
// gateway's version of this bug invisible for a year.
func TestEdgeInstallShDestinationIsTheOneSystemBinDir(t *testing.T) {
	src := readFile(t, installShPath(t))

	for _, want := range []string{
		`SYS_BIN_DIR="${SYS_BIN_DIR:-` + wantBinDirDefault + `}"`,
		`BIN_DIR="$SYS_BIN_DIR"`,
	} {
		if !strings.Contains(src, want) {
			t.Errorf("install.sh no longer contains %q — the single destination moved shape "+
				"and this test can no longer pin it (update the gateway's sibling pin in the same change)", want)
		}
	}
	for _, banned := range []string{
		`BIN_DIR="${PREFIX:-$HOME/.local}/bin"`,
		`COMP_HOME="$HOME/.burrowee/$COMP"`,
		"if is_root; then",
	} {
		if strings.Contains(src, banned) {
			t.Errorf("install.sh still carries %q — the per-user flow is supposed to be gone, "+
				"not disabled; a surviving privilege fork re-gates the whole privileged surface", banned)
		}
	}
}

// TestEdgeInstallRefusesAMisdirectingPrefix — silently overriding a PREFIX that
// names somewhere else would be the same class of surprise as the bug this
// collapse fixes, pointed the other way: the operator asks for one directory and
// a different one is written, root-owned, without a word. So the run must FAIL,
// name what changed and where things go now, and do it before anything is
// placed.
//
// The $HOME/.local it uses is genuinely divergent, so this stays exactly as true
// under the divergent-only rule; prefix_gate_test.go owns the other half (a
// PREFIX that resolves to $BIN_DIR is honoured).
func TestEdgeInstallRefusesAMisdirectingPrefix(t *testing.T) {
	for _, shell := range shellsUnderTest(t) {
		t.Run(filepath.Base(shell), func(t *testing.T) {
			sb := newSandbox(t)
			out, err := sb.run(t, shell, stubRootEnv(t), "PREFIX="+filepath.Join(sb.home, ".local"))
			if err == nil {
				t.Fatalf("install.sh honoured PREFIX instead of refusing it:\n%s", out)
			}
			assertContains(t, out, "PREFIX", collapseVersion, wantBinDirDefault, "nothing has been installed")
			sb.assertNothingPlaced(t, out)
		})
	}
}

// TestEdgeInstallRefusesAnUnprivilegedRun — the other half of "one shape". An
// unprivileged run cannot write a unit, and on an Intel Mac (Homebrew owns
// /usr/local) it CAN write the binaries, so the shape it would otherwise
// produce is a half-installed edge with no service and an execution surface a
// non-root user can rewrite. $SYS_BIN_DIR here is a writable sandbox dir for
// exactly that reason: a run that failed to refuse would leave the binaries
// behind, and this test would see them.
func TestEdgeInstallRefusesAnUnprivilegedRun(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: the `id -u` stub cannot make this run unprivileged")
	}
	for _, shell := range shellsUnderTest(t) {
		t.Run(filepath.Base(shell), func(t *testing.T) {
			sb := newSandbox(t)
			out, err := sb.run(t, shell, stubNonRootEnv(t))
			if err == nil {
				t.Fatalf("an unprivileged install.sh exited 0 — it must refuse:\n%s", out)
			}
			assertContains(t, out, "must run as root", "sudo", "nothing has been installed")
			sb.assertNothingPlaced(t, out)
			if _, statErr := os.Stat(filepath.Join(sb.home, ".local", "bin")); statErr == nil {
				t.Errorf("the refused run still created the per-user bin dir:\n%s", out)
			}
		})
	}
}

// stubNonRootEnv is stubRootEnv's counterpart: `id -u` reports an ordinary uid
// so is_root is false, and `uname -s` reports Linux so the run is pinned to the
// Linux shape whatever the test host is. No systemctl stub — a refused run
// reaches no init system, and one that did would be taking a branch this test
// exists to prove is gone.
func stubNonRootEnv(t *testing.T) string {
	t.Helper()
	stub := t.TempDir()
	stubBin(t, stub, "id", "#!/bin/sh\nif [ \"$1\" = \"-u\" ]; then echo 1000; else echo \"id $*\" >> \"$STUB_LOG\"; fi\n")
	stubBin(t, stub, "uname", "#!/bin/sh\nif [ \"$1\" = \"-s\" ]; then echo Linux; else /usr/bin/uname \"$@\"; fi\n")
	return stub
}

// TestEdgeInstallCompletesUnderEveryShell runs the WHOLE install — the only
// install there is now — under each shell, and requires the three separable
// products of the privileged surface: binaries placed, units rendered, unit
// handed to the init system. Nothing in this package asserted them as one claim
// from a plain default run before, and the dialect coverage is what a
// bash-only suite kept missing (the /dev/tty defect, dash-only, shipped from
// this file).
func TestEdgeInstallCompletesUnderEveryShell(t *testing.T) {
	for _, shell := range shellsUnderTest(t) {
		t.Run(filepath.Base(shell), func(t *testing.T) {
			sb := newSandbox(t)
			out, err := sb.run(t, shell, stubRootEnv(t),
				"BURROWEE_VERSION=edge/v0.2.0.2026.08.14.abcdef12")
			if err != nil {
				t.Fatalf("install.sh failed under %s: %v\n%s", shell, err, out)
			}
			for _, b := range edgeBins {
				if _, statErr := os.Stat(filepath.Join(sb.sysBinDir, b)); statErr != nil {
					t.Errorf("%s not placed in the system bin dir under %s: %v", b, shell, statErr)
				}
			}
			for _, unit := range []string{"burrowee-edge.service", "burrowee-edge-updater.service"} {
				if _, statErr := os.Stat(filepath.Join(sb.unitDir, unit)); statErr != nil {
					t.Errorf("%s not rendered under %s: %v", unit, shell, statErr)
				}
			}
			if log := readFile(t, filepath.Join(sb.home, "stub-calls.log")); !strings.Contains(log, "enable --now burrowee-edge") {
				t.Errorf("the init system was never asked to run the unit under %s:\n%s", shell, log)
			}
			// The version anchor lands in the machine-owned CONFIG root —
			// not the invoking user's home and not root's either. It is the
			// ladder's gate, and it must sit in the tree that is backed up
			// and never cleared.
			marker := filepath.Join(sb.compHome(), "installed-version")
			if got, statErr := os.ReadFile(marker); statErr != nil {
				t.Errorf("no version marker at %s under %s: %v", marker, shell, statErr)
			} else if strings.TrimSpace(string(got)) != "edge/v0.2.0.2026.08.14.abcdef12" {
				t.Errorf("version marker = %q under %s", strings.TrimSpace(string(got)), shell)
			}
			assertContains(t, out, "edge system install complete")
		})
	}
}

// TestEdgeInstallReportsAnOrphanedPerUserIdentity — the migration hazard the
// collapse creates, made loud. A host that paired under the pre-collapse
// per-user layout has its identity under the OPERATOR's home; the managed
// daemon reads root's. Nothing moves it, so the install would otherwise exit 0
// with a healthy, running, UNPAIRED edge and no reason for the operator to look
// for the identity sitting a directory away.
//
// The operator account resolves only through the LEGACY_HOME_PARENTS fallback,
// so this can never reach a real home.
func TestEdgeInstallReportsAnOrphanedPerUserIdentity(t *testing.T) {
	sb := newSandbox(t)
	parents := t.TempDir()
	operator := "burrowee-fixture-operator"
	operatorState := filepath.Join(parents, operator, ".burrowee", "edge")
	if err := os.MkdirAll(filepath.Join(operatorState, "identity"), 0o755); err != nil {
		t.Fatal(err)
	}

	out, err := sb.run(t, "sh", stubRootEnv(t),
		"SUDO_USER="+operator,
		"BURROWEE_LEGACY_HOME_PARENTS="+parents)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	assertContains(t, out, operatorState, "starts UNPAIRED")

	// And it is REPORTED, never touched: the identity is the only copy there is.
	if _, statErr := os.Stat(filepath.Join(operatorState, "identity")); statErr != nil {
		t.Errorf("the installer removed the per-user identity tree: %v", statErr)
	}
}

// TestEdgeInstallSaysNothingWhenTheRootTreeIsAlreadyPaired is the contrast that
// makes the test above mean something: on a re-install of an already-paired root
// edge the per-user tree is merely history, and a warning about it every time
// would be noise the operator learns to ignore.
func TestEdgeInstallSaysNothingWhenTheRootTreeIsAlreadyPaired(t *testing.T) {
	sb := newSandbox(t)
	parents := t.TempDir()
	operator := "burrowee-fixture-operator"
	operatorState := filepath.Join(parents, operator, ".burrowee", "edge")
	if err := os.MkdirAll(filepath.Join(operatorState, "identity"), 0o755); err != nil {
		t.Fatal(err)
	}
	// This host's machine-owned CONFIG root is already paired.
	if err := os.MkdirAll(sb.compHome(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sb.compHome(), "console.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}

	out, err := sb.run(t, "sh", stubRootEnv(t),
		"SUDO_USER="+operator,
		"BURROWEE_LEGACY_HOME_PARENTS="+parents)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	if strings.Contains(out, "starts UNPAIRED") {
		t.Errorf("warned about an orphaned identity on an already-paired host:\n%s", out)
	}
}
