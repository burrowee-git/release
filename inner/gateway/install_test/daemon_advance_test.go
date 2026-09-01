// Daemon-advance coverage: an install that finishes must leave the SUPERVISOR
// executing the file the install just placed, on both platform branches.
//
// This is step 5 of the install contract — "kill old instance, re-run with
// newly installed file". Darwin has always done it (bootout + bootstrap);
// Linux did not, and nothing caught that because the suite selected its
// assertions with runtime.GOOS while install.sh selects its behaviour with
// `uname -s`. Every test here therefore forces the platform (stubInitSystemFor)
// rather than reading the host's, so the Linux half runs on the macOS release
// machine where this bug was found.
package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// systemctlCalls returns the bare `systemctl …` lines the stub recorded, one
// per real invocation. The pass-through sudo stub logs its own
// "sudo -n systemctl …" line and then execs systemctl, which logs
// "systemctl …" — so matching whole lines against the bare form counts each
// call exactly once.
func systemctlCalls(t *testing.T, home string) []string {
	t.Helper()
	var calls []string
	for _, line := range strings.Split(readFile(t, filepath.Join(home, "stub-calls.log")), "\n") {
		if s := strings.TrimSpace(line); strings.HasPrefix(s, "systemctl ") {
			calls = append(calls, s)
		}
	}
	return calls
}

// countCall returns how many recorded calls equal want.
func countCall(calls []string, want string) int {
	n := 0
	for _, c := range calls {
		if c == want {
			n++
		}
	}
	return n
}

// TestLinuxInstallRestartsTheGatewayDaemon is the regression guard for the
// observed field state: install.sh exits 0, the unit is correctly rewritten to
// the privileged tree, and the daemon goes on executing its OLD per-user
// ExecStart until the host reboots — `doctor` reporting
// "installed v… · running v… ⚠ drift", and the security fix the unit rewrite
// exists for silently not in effect.
//
// `systemctl enable --now` is a no-op on a unit that is already running, so the
// enable alone never advanced anything. The restart is the step that does.
func TestLinuxInstallRestartsTheGatewayDaemon(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystemFor(t, "linux")
	seedMigrateCapableCLI(t, home)

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	calls := systemctlCalls(t, home)
	if countCall(calls, "systemctl restart burrowee-gateway.service") == 0 {
		t.Errorf("install finished without restarting the gateway — the daemon keeps running the OLD binary until reboot; systemctl calls:\n%s",
			strings.Join(calls, "\n"))
	}
}

// TestFreshInstallHandsTheRestartToTheGuard restores, in the shape the
// guarded-restart architecture actually offers, the guarantee
// TestLinuxFreshInstallRestartsTheGatewayDaemon used to cover from the OTHER
// entry point that reached load_units: a plain default (fresh) install with
// no mode flag. Run on both platform shapes (forcedOSes), the same discipline
// TestBothPlatformsAdvanceTheDaemon below already applies to the units-only
// entry point — a Linux-only version of this would have missed exactly the
// kind of platform-specific gap this whole file exists to catch.
//
// THAT ENTRY POINT NO LONGER REACHES load_units AT ALL, BY DESIGN. A fresh
// install is exactly the case an operator runs from an SSH session tunnelled
// THROUGH the gateway it is installing — load_units restarting the daemon in
// this script's own foreground severed that session mid-install, silently
// skipping everything after it, the version anchor included. The restart is
// now the guard's job (guard_arm, armed before the first write), running in a
// detached child that outlives this shell and this connection.
//
// WHY THE ORIGINAL COULD NOT SIMPLY BE REPAIRED, and still cannot: a
// synchronous check of stub-calls.log right after runStaged returns cannot
// observe the guard's OWN restart of the serve unit — the guard is a process
// glued to launchd/systemd, and this suite's own stubs for those only RECORD
// a call rather than actually spawning the guard process behind it
// (stubInitSystem's header explains why: a real systemd-run would hand a live
// transient unit to the HOST's own systemd). Asserting the guard's restart
// from here would either race a process that never runs, or assert a promise
// this script's foreground no longer makes at all.
//
// WHAT THIS TEST ASSERTS INSTEAD, now that Task 9 has written the handoff:
// the two facts that ARE true synchronously, by the time this script's
// foreground returns — the guard itself was handed off to the init system
// (guardArmCallFor), and the transaction reached the "handoff" phase, the
// token that means the restart is now the guard's problem, not this script's.
// The guard's own restart-and-verify path (that it actually issues
// `systemctl restart burrowee-gateway.service` / `launchctl kickstart -k`
// once handed off) is covered end-to-end against the real guard.sh by
// tools/guard-rollback.test.sh's t_guard_ok / t_guard_rolls_back, on both
// platform shapes — this test's job is only that install.sh gets the handoff
// there.
func TestFreshInstallHandsTheRestartToTheGuard(t *testing.T) {
	for _, goos := range forcedOSes {
		t.Run(goos, func(t *testing.T) {
			home := t.TempDir()
			stub := stubInitSystemFor(t, goos)
			staging := t.TempDir()
			seedDummyBins(t, staging)

			if out, err := runStaged(t, installShPath(t), staging, home, stub); err != nil {
				t.Fatalf("fresh install failed: %v\n%s", err, out)
			}

			calls := readFile(t, filepath.Join(home, "stub-calls.log"))
			if !strings.Contains(calls, guardArmCallFor(goos)) {
				t.Errorf("%s: fresh install never handed the guard to the init system (want %q); init calls:\n%s",
					goos, guardArmCallFor(goos), calls)
			}
			if got := latestTxnPhase(t, home); got != "handoff" {
				t.Errorf("%s: transaction phase = %q, want %q — the foreground flow did not hand the restart to the guard", goos, got, "handoff")
			}
		})
	}
}

// TestLinuxConvergedReinstallStillRestartsTheGatewayDaemon pins the restart
// CONDITION, which is the design decision this change turns on: the restart is
// unconditional, not gated on "a binary or the unit body actually changed".
//
// The second run below changes nothing — place_unit reports both units
// "(unchanged)" and ensure_root_exec_surface's cmp finds every privileged
// binary already identical — and it must STILL restart. A change-detecting
// guard cannot see the state that created this bug: files already converged,
// process still stale. That is precisely the host an operator brings to
// `burrowee gateway service install` to repair drift, so a guard would decline
// exactly when the documented remedy is run, and the repair would be a no-op
// for the second time.
//
// Bouncing a healthy daemon is the acknowledged cost. It is bounded by who can
// reach load_units at all — fresh install and units-only, both operator or
// console initiated verbs — and by the two paths that must never restart, each
// covered by its own test below.
func TestLinuxConvergedReinstallStillRestartsTheGatewayDaemon(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystemFor(t, "linux")
	seedMigrateCapableCLI(t, home)

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")
	if err := os.Remove(filepath.Join(home, "stub-calls.log")); err != nil {
		t.Fatalf("reset stub log: %v", err)
	}
	out := runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	// Precondition: the second run really is the no-op case. Without this the
	// test could pass because something changed, proving nothing about the
	// condition.
	assertContains(t, out,
		filepath.Join(systemdDir(home), "burrowee-gateway.service")+" (unchanged)",
		filepath.Join(systemdDir(home), "burrowee-gateway-updater.service")+" (unchanged)",
	)

	calls := systemctlCalls(t, home)
	if countCall(calls, "systemctl restart burrowee-gateway.service") == 0 {
		t.Errorf("a converged reinstall did not restart the gateway — that is the drift-repair path, and it must advance the daemon; systemctl calls:\n%s",
			strings.Join(calls, "\n"))
	}
}

// TestLinuxUpdateModeNeverRestartsTheGateway is the self-kill guard, and the
// reason the restart lives in load_units rather than beside render_units.
//
// BURROWEE_UPDATE is the updater's own push path: the process running this
// script is the thing a restart would kill, and a half-applied update is worse
// than a stale one. That mode renders unit FILES and never calls load_units —
// a structural exclusion, not a flag — so no restart of any kind may appear.
func TestLinuxUpdateModeNeverRestartsTheGateway(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystemFor(t, "linux")
	staging := t.TempDir()
	seedDummyBins(t, staging)
	seedMigrateCapableCLI(t, home)

	out, err := runStaged(t, installShPath(t), staging, home, stub, "BURROWEE_UPDATE=1")
	if err != nil {
		t.Fatalf("update mode failed: %v\n%s", err, out)
	}

	// Sanity: the unit files WERE refreshed, so the absence below is about the
	// restart and not about update mode having bailed out early.
	if _, statErr := os.Stat(filepath.Join(systemdDir(home), "burrowee-gateway.service")); statErr != nil {
		t.Fatalf("update mode did not render the core unit: %v", statErr)
	}

	for _, c := range systemctlCalls(t, home) {
		if strings.HasPrefix(c, "systemctl restart ") ||
			strings.HasPrefix(c, "systemctl enable --now ") ||
			strings.HasPrefix(c, "systemctl start ") {
			t.Errorf("update mode issued %q — that restarts the process running this very script:\n%s",
				c, strings.Join(systemctlCalls(t, home), "\n"))
		}
	}
}

// TestLinuxReportsAFailedGatewayRestart covers the state that must never be
// silent: the restart failed, so the host now has NEW binaries on disk under an
// OLD running daemon — an install that looks clean and has not taken effect.
// That is the drift state this whole change exists to end, so a swallowed
// failure would simply relocate it.
//
// Non-fatal on purpose: the unit files on disk are still the durable outcome
// and a supervisor-less host (a container, where every systemctl call fails)
// must still complete its install — the same best-effort contract every other
// step in load_units keeps. Loud, not fatal.
func TestLinuxReportsAFailedGatewayRestart(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystemFor(t, "linux")
	seedMigrateCapableCLI(t, home)

	// runInstallSh fails the test on a non-zero exit, so using it here asserts
	// the "non-fatal" half.
	out := runInstallSh(t, home, stub,
		"BURROWEE_UNITS_ONLY=1",
		"STUB_SYSTEMCTL_FAIL=restart burrowee-gateway.service",
	)

	// Precondition: the stub really did refuse the call under test.
	if countCall(systemctlCalls(t, home), "systemctl restart burrowee-gateway.service") == 0 {
		t.Fatalf("the restart was never attempted, so nothing could fail; output:\n%s", out)
	}
	assertContains(t, out,
		"systemctl restart burrowee-gateway.service' failed",
		"the daemon still running is the",
		"sudo systemctl restart burrowee-gateway.service",
	)
}

// TestBothPlatformsAdvanceTheDaemon is the test the original defect needed and
// no assertion could provide: the two branches must offer the SAME guarantee,
// checked side by side in one run, on one host.
//
// Darwin advances the daemon with `kickstart -k`, Linux by restarting the unit.
// Different verbs, one contract — the supervisor ends up executing the file this
// install placed. Written as a table so that a future branch (or a branch that
// quietly loses its step, which is exactly what happened) fails here rather
// than in the field.
//
// THE DARWIN ROW USED TO NAME `launchctl bootout system/com.burrowee.gateway`,
// and it was a SUBSTRING match — so once the serve label's bootout was removed
// it went on passing, satisfied by the UPDATER's own bootout line
// (`…gateway.updater`) that load_units still emits. A test whose header says it
// exists so "a branch that quietly loses its step fails here rather than in the
// field" was passing with the step gone. The row now names the verb that
// actually advances the serve label, and it is the FULL line: the trailing
// label is what stops `…gateway` from matching `…gateway.updater` again.
func TestBothPlatformsAdvanceTheDaemon(t *testing.T) {
	advance := map[string]string{
		"darwin": "launchctl kickstart -k system/com.burrowee.gateway\n",
		"linux":  "systemctl restart burrowee-gateway.service\n",
	}

	for _, goos := range forcedOSes {
		t.Run(goos, func(t *testing.T) {
			home := t.TempDir()
			stub := stubInitSystemFor(t, goos)
			seedMigrateCapableCLI(t, home)

			runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

			calls := readFile(t, filepath.Join(home, "stub-calls.log"))
			if !strings.Contains(calls, advance[goos]) {
				t.Errorf("%s: install never advanced the running daemon (want %q) — new files on disk, old process serving; init calls:\n%s",
					goos, advance[goos], calls)
			}
		})
	}
}
