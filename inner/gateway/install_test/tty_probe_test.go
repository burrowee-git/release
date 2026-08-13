// tty_probe_test.go — the first-run setup prompt's /dev/tty probe, under every
// shell /bin/sh is on a host that runs this component.
//
// The suite already covered the no-tty case (migration_gate_test.go,
// TestFreshInstallPromptsSetupOnAVirginHost) — under `sh`, which on the macOS
// release machine is bash. It is dash on every Debian-family host, and dash
// treats a FAILED `exec` redirection as fatal: it exits the script, status 2,
// with nothing left for a `2>/dev/null` to hide, even when the `exec` sits in a
// brace group used as an `if` condition. So the probe that asks "is there a
// terminal to prompt on" ANSWERED by killing the script, at the very last step
// of an otherwise complete install.
//
// What that cost, on the hosts it happened on: every non-interactive install —
// CI, a console push, `curl … | sh` under a supervisor, and every run of this
// package on Linux — placed all six binaries, wrote and loaded both units,
// recorded the version, and then exited non-zero with no explanation. Any
// caller checking the exit status saw a failed install and had every reason to
// retry or roll back a gateway that was, in fact, fully installed.
//
// This is the same class of blindness as the `stat -f` dialect bug
// (stat_portability_test.go): coverage that exists, and never runs under the
// shell that matters. Hence the loop over shellsUnderTest rather than a plain
// `sh` — under `sh` alone this test passes on macOS whether the bug is present
// or not.
package install_test

import (
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// TestFreshInstallOnAVirginHostSucceedsWithNoTtyUnderEveryShell installs onto a
// host with no gateway state and no controlling terminal, and requires a clean
// exit plus the "run this next" line the probe's else-branch prints.
//
// Setsid is what makes /dev/tty genuinely unopenable: `go test` run from a
// terminal otherwise hands the child the suite's own controlling terminal, and
// the installer would take the interactive branch and block on a read.
func TestFreshInstallOnAVirginHostSucceedsWithNoTtyUnderEveryShell(t *testing.T) {
	for _, shell := range shellsUnderTest(t) {
		t.Run(filepath.Base(shell), func(t *testing.T) {
			home := t.TempDir()
			stub := stubInitSystem(t)
			staging := t.TempDir()
			seedDummyBins(t, staging)

			cmd := exec.Command(shell, installShPath(t))
			cmd.Dir = staging
			cmd.Env = installShEnv(home, stub)
			cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("a complete install exited non-zero under %s with no tty: %v\n%s", shell, err, out)
			}

			// The else-branch's own line. Without it the install could have
			// exited 0 having skipped the whole first-run step for some other
			// reason, and this test would be asserting nothing about the probe.
			if !strings.Contains(string(out), "next: burrowee gateway bootstrap") {
				t.Errorf("the no-tty branch never ran under %s — the probe did not reach it:\n%s", shell, out)
			}
		})
	}
}
