// tty_probe_test.go — the NON-ROOT install path, and the first-run setup
// prompt's /dev/tty probe that ends it, under every shell /bin/sh is on a host
// that runs the edge.
//
// Two gaps met here. The first: the rest of this package only ever exercises the
// ROOT branch, which `exit 0`s at "edge system install complete" — so nothing
// below that line, including the whole unprivileged tail of the script, had any
// coverage at all. The second: what runs there is run under a bare `sh`, which
// is bash 3.2 on the macOS release machine and dash on every Debian-family host.
//
// dash treats a FAILED `exec` redirection as fatal: it exits the script, status
// 2, with nothing left for the guard's `2>/dev/null` to hide, even when the
// `exec` sits in a brace group used as an `if` condition (a brace group is not a
// subshell, so it does not contain the exit). The probe asking "is there a
// terminal to prompt on" therefore ANSWERED by killing the script — as the very
// last statement of an otherwise complete install. Reproduced on a Debian
// container: an unprivileged install placed every binary, printed the user-path
// note, and exited 2; the same tree under bash exited 0.
//
// Both gaps have to be closed together, and both are load-bearing here: under
// `sh` alone this test passes on macOS whether the bug is present or not, and
// under the root branch alone it never reaches the line at all.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// shellsUnderTest is every POSIX shell available here that install.sh must run
// under. `sh` is whatever the host's /bin/sh is — bash 3.2 on macOS, dash on
// Debian-family — and dash and bash are named explicitly so a run on either
// platform still exercises BOTH dialects when they are installed. Missing
// shells are skipped with a note rather than failing: not every host has both.
// Mirrors the gateway suite's helper of the same name.
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

// stubNonRootEnv is stubRootEnv's counterpart: `id -u` reports an ordinary uid
// so is_root is false, and `uname -s` reports Linux so the run is pinned to the
// Linux shape whatever the test host is (on Darwin the binary loop would call
// xattr). No systemctl stub — the non-root path installs no service, and a run
// that reached systemctl would be taking the root branch this test exists to
// avoid.
func stubNonRootEnv(t *testing.T) string {
	t.Helper()
	stub := t.TempDir()
	stubBin(t, stub, "id", "#!/bin/sh\nif [ \"$1\" = \"-u\" ]; then echo 1000; else echo \"id $*\" >> \"$STUB_LOG\"; fi\n")
	stubBin(t, stub, "uname", "#!/bin/sh\nif [ \"$1\" = \"-s\" ]; then echo Linux; else /usr/bin/uname \"$@\"; fi\n")
	return stub
}

// TestEdgeNonRootInstallSucceedsWithNoTtyUnderEveryShell installs as an ordinary
// user onto a host with no edge state and no controlling terminal, and requires
// a clean exit plus the "run this next" line the probe's else-branch prints.
//
// Setsid is what makes /dev/tty genuinely unopenable: `go test` run from a
// terminal otherwise hands the child the suite's own controlling terminal, the
// installer takes the interactive branch and blocks on a read, and the probe
// this test exists to exercise never fails in the first place.
func TestEdgeNonRootInstallSucceedsWithNoTtyUnderEveryShell(t *testing.T) {
	for _, shell := range shellsUnderTest(t) {
		t.Run(filepath.Base(shell), func(t *testing.T) {
			home := t.TempDir()
			staging := t.TempDir()
			seedEdgeBins(t, staging)
			stub := stubNonRootEnv(t)

			cmd := exec.Command(shell, installShPath(t))
			cmd.Dir = staging
			cmd.Env = []string{
				"HOME=" + home,
				"PREFIX=" + filepath.Join(home, ".local"),
				"PATH=" + stub + ":/usr/bin:/bin",
				"STUB_LOG=" + filepath.Join(home, "stub-calls.log"),
			}
			cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
			out, err := cmd.CombinedOutput()
			// THE assertion: a fully installed edge that reports failure is
			// the whole defect. Status, not filesystem state — every file
			// below was already on disk when this exited 2.
			if err != nil {
				t.Fatalf("a complete unprivileged install exited non-zero under %s with no tty: %v\n%s", shell, err, out)
			}

			// This run must genuinely have taken the NON-ROOT path. The root
			// branch `exit 0`s well before the probe, so without these checks
			// a stub that leaked uid 0 would give a green test that never
			// reached the line under test.
			if !strings.Contains(string(out), "user path, no managed service") {
				t.Errorf("install did not take the non-root path under %s:\n%s", shell, out)
			}
			if strings.Contains(string(out), "edge system install complete") {
				t.Errorf("install took the ROOT path under %s — it never reaches the tty probe:\n%s", shell, out)
			}
			binDir := filepath.Join(home, ".local", "bin")
			for _, b := range edgeBins {
				if _, err := os.Stat(filepath.Join(binDir, b)); err != nil {
					t.Errorf("binary not installed to the user bin dir under %s: %s: %v", shell, b, err)
				}
			}

			// The else-branch's own line. Without it the install could have
			// exited 0 having skipped the whole first-run step for some other
			// reason (an already-enrolled $COMP_HOME, say), and this test would
			// be asserting nothing about the probe.
			if !strings.Contains(string(out), "next: burrowee edge cli bootstrap") {
				t.Errorf("the no-tty branch never ran under %s — the probe did not reach it:\n%s", shell, out)
			}
		})
	}
}
