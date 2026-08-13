// tty_probe_test.go — the first-run setup prompt's /dev/tty probe, under every
// shell /bin/sh is on a host that runs the cli.
//
// The rest of this package runs install.sh under a bare `sh`. On the macOS
// release machine that is bash 3.2; on every Debian-family host it is dash, and
// dash treats a FAILED `exec` redirection as fatal: it exits the script, status
// 2, with nothing left for the guard's `2>/dev/null` to hide, even when the
// `exec` sits in a brace group used as an `if` condition (a brace group is not a
// subshell, so it does not contain the exit). So the probe that asks "is there a
// terminal to prompt on" ANSWERED by killing the script, at the very last step
// of an otherwise complete install — after the binaries were placed and before
// the self-copy LocalReinstall needs.
//
// This is the same class of blindness as the gateway suite's `stat -f` dialect
// bug: coverage that exists, and never runs under the shell that matters. Hence
// the loop over shellsUnderTest rather than a plain `sh` — under `sh` alone this
// test passes on macOS whether the bug is present or not.
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

// TestCliFreshInstallSucceedsWithNoTtyUnderEveryShell installs onto a host with
// no cli state and no controlling terminal, and requires a clean exit plus the
// "run this next" line the probe's else-branch prints.
//
// runInstall's Setsid is what makes /dev/tty genuinely unopenable: `go test`
// run from a terminal otherwise hands the child the suite's own controlling
// terminal, the installer takes the interactive branch, and the probe that this
// test exists to exercise never fails in the first place.
func TestCliFreshInstallSucceedsWithNoTtyUnderEveryShell(t *testing.T) {
	for _, shell := range shellsUnderTest(t) {
		t.Run(filepath.Base(shell), func(t *testing.T) {
			home := t.TempDir()
			staging := t.TempDir()
			seedCliBins(t, staging)

			// runInstallUnder fails the test itself on a non-zero exit —
			// which IS the assertion: a fully installed cli that reports
			// failure is the whole defect.
			out := runInstallUnder(t, shell, home, staging)

			// The else-branch's own line. Without it the install could have
			// exited 0 having skipped the whole first-run step for some other
			// reason (an already-set-up $COMP_HOME, say), and this test would
			// be asserting nothing about the probe.
			if !strings.Contains(out, "next: burrowee cli bootstrap") {
				t.Errorf("the no-tty branch never ran under %s — the probe did not reach it:\n%s", shell, out)
			}
		})
	}
}

// runInstallUnder is runInstall with an explicit shell. Kept here beside the
// only tests that vary it; runInstall delegates with "sh".
func runInstallUnder(t *testing.T, shell, home, staging string, extraEnv ...string) string {
	t.Helper()
	cmd := exec.Command(shell, installShPath(t))
	cmd.Dir = staging
	cmd.Env = append([]string{
		"HOME=" + home,
		"PREFIX=" + filepath.Join(home, ".local"),
		"PATH=/usr/bin:/bin",
	}, extraEnv...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Logf("install.sh output:\n%s", out)
		t.Fatalf("install.sh under %s failed: %v", shell, err)
	}
	return string(out)
}
