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
//
// WHERE THAT CONTRACT LIVES NOW, AND WHY THIS FILE CHANGED SHAPE AGAIN.
// install.sh's foreground does not advance the daemon on ANY path any more.
// The fresh path stopped at Task 7; BURROWEE_UNITS_ONLY — `service install`
// and `doctor --fix` — stopped when it too was guarded, because it is typed by
// an operator whose session routinely runs THROUGH the daemon it restarts, and
// a restart in this script's own foreground is what severed that session. Four
// tests here drove units-only specifically BECAUSE it was the last synchronous
// restart path; they are retargeted rather than deleted, and each one says
// below which half of its claim it keeps and where the other half went.
//
// The division is the same for all of them:
//
//   - "install.sh must hand the restart to the guard, and must not perform one
//     itself" — still this file's, still checked here, on both platform shapes.
//   - "the guard advances the daemon with the right verb, exactly once,
//     without unloading the serve label, unconditionally, and reports loudly
//     when the new build does not come up" — tools/guard-rollback.test.sh,
//     against the real guard.sh driven by a real (fake) supervisor. It cannot
//     be checked here: this suite's launchctl/systemd-run stubs RECORD the arm
//     and never spawn the guard behind it (stubInitSystem's own header gives
//     the reason — a real systemd-run would hand a live transient unit to the
//     HOST's systemd), so the calls these tests used to count are not made in
//     this process at all.
package install_test

import (
	"os"
	"os/exec"
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

// TestLinuxUnitsOnlyIssuesNoRestartOfItsOwn is the same code path as the test
// it replaces (TestLinuxInstallRestartsTheGatewayDaemon) with the claim
// inverted, because the finding inverted it.
//
// That test guarded the observed field state where install.sh exits 0, the
// unit is correctly rewritten to the privileged tree, and the daemon goes on
// executing its OLD per-user ExecStart until the host reboots — `enable --now`
// being a no-op on a running unit, so the enable alone advanced nothing. The
// remedy then was "restart here". The remedy now is "restart, but not HERE":
// this is the path `burrowee gateway service install` and `doctor --fix` take,
// an operator's session is routinely tunnelled through the daemon in question,
// and a foreground `systemctl restart` on it kills the shell running the
// installer at the exact moment there is still work left to do.
//
// So the daemon must still be advanced — by the guard, proven in
// tools/guard-rollback.test.sh (t_guard_ok, t_guard_does_not_flap_the_units,
// on both platform shapes) — and this script's own foreground must issue no
// serve-unit start of any kind. That second half is what a regression would
// silently undo (a well-meaning "the units are loaded, just enable them"), and
// it is what this checks.
//
// The handoff itself is asserted in TestBothPlatformsHandTheRestartToTheGuard
// below: without it this test would also pass on a mode that simply stopped
// doing anything.
func TestLinuxUnitsOnlyIssuesNoRestartOfItsOwn(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystemFor(t, "linux")
	seedMigrateCapableCLI(t, home)

	runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

	calls := systemctlCalls(t, home)
	for _, c := range calls {
		// `systemctl --user disable --now` is remove_legacy_user_units tearing
		// down the pre-system-level per-user units; it is not a start of the
		// managed system unit and must still fire.
		if strings.HasPrefix(c, "systemctl --user ") {
			continue
		}
		if strings.HasPrefix(c, "systemctl restart ") ||
			strings.HasPrefix(c, "systemctl enable --now ") ||
			strings.HasPrefix(c, "systemctl start ") {
			t.Errorf("units-only issued %q in install.sh's own foreground — on a gateway that is the connection the operator is reading this output over, and everything after it (the version anchor above all) silently never runs; systemctl calls:\n%s",
				c, strings.Join(calls, "\n"))
		}
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

// TestLinuxConvergedReinstallStillHandsOff pins the restart CONDITION, which
// is the design decision this whole line of work turns on: the restart is
// unconditional, not gated on "a binary or the unit body actually changed".
//
// The second run below changes nothing — place_unit reports both units
// "(unchanged)" and ensure_root_exec_surface's cmp finds every privileged
// binary already identical — and the daemon must STILL be advanced. A
// change-detecting guard cannot see the state that created this bug: files
// already converged, process still stale. That is precisely the host an
// operator brings to `burrowee gateway service install` to repair drift, so
// such a guard would decline exactly when the documented remedy is run.
//
// WHAT MOVED, AND WHY THIS IS STILL THE TEST FOR IT. The unconditional step
// used to be `systemctl restart` in this script's foreground; it is now the
// handoff, and the guard restarts unconditionally once handed off (guard.sh's
// do_restart takes no "did anything change" argument — restart_mode only
// decides whether launchd must RE-READ the plist, never whether to restart).
// So the condition is asserted at the point install.sh still owns: a converged
// re-run must arm a guard and reach `handoff` exactly as a changed one does.
// The guard's own end of it — that a handoff always produces a restart, and
// that an UNCHANGED unit body still gets a kickstart rather than being skipped
// — is tools/guard-rollback.test.sh's t_guard_does_not_reload_an_unchanged_-
// unit_body and t_guard_does_not_flap_the_units.
//
// Bouncing a healthy daemon is the acknowledged cost, bounded by who can reach
// the handoff at all: fresh install and units-only, both operator or console
// initiated verbs, and never BURROWEE_UPDATE (the test below).
func TestLinuxConvergedReinstallStillHandsOff(t *testing.T) {
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

	calls := readFile(t, filepath.Join(home, "stub-calls.log"))
	if !strings.Contains(calls, guardArmCallFor("linux")) {
		t.Errorf("a converged reinstall armed no guard (want %q) — the drift-repair path did nothing, which is the second no-op this test exists to prevent; init calls:\n%s",
			guardArmCallFor("linux"), calls)
	}
	if got := latestTxnPhase(t, home); got != "handoff" {
		t.Errorf("a converged reinstall left the transaction at %q, want %q — the daemon is never advanced, so `service install` cannot repair the drift it is documented to repair", got, "handoff")
	}
}

// TestLinuxUpdateModeNeverRestartsTheGateway is the self-kill guard.
//
// BURROWEE_UPDATE is the updater's own push path: the process running this
// script is the thing a restart would kill, and a half-applied update is worse
// than a stale one. That mode renders unit FILES and never calls load_units —
// a structural exclusion, not a flag — so no restart of any kind may appear.
//
// IT ALSO ARMS NO GUARD, and that asymmetry is deliberate rather than an
// oversight in the guarding work: the mode restarts nothing to guard, runs
// under a daemon with no operator session to sever, already carries its own
// per-binary rollback, and a guard there would have to restart the process it
// is running underneath. guard.sh's header ("WHICH INSTALL MODES ARM A GUARD")
// records the full argument; the assertion below is its enforcement.
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

	calls := readFile(t, filepath.Join(home, "stub-calls.log"))
	if strings.Contains(calls, guardArmCallFor("linux")) {
		t.Errorf("update mode armed an install guard (%q) — it would sit under the updater it must restart, which is the deadlock this whole design removes; init calls:\n%s",
			guardArmCallFor("linux"), calls)
	}
}

// TestUnitsOnlyReportsAFailedRestartAndStillBanksTheAnchor covers the state
// that must never be silent — the restart failed, so the host has new units
// (and, on a migrated host, moved state) with a daemon that is not serving —
// and it covers it where that state is now DETECTED.
//
// It used to assert install.sh's own loud `systemctl restart … failed` block,
// reached by making the stub refuse that call. That block is in load_units, and
// no mode calls load_units any more: this path hands the restart to a guard
// that runs after install.sh's foreground is done, so the failure happens in a
// process this one cannot observe. Asserting the old message would be
// asserting a string on a code path nothing on this component executes.
//
// The successor is reattach. The guard writes its verdict into the transaction
// phase file; install.sh polls it and turns `rolled-back` into a message and a
// non-zero exit. STUB_GUARD_VERDICT (stubInitSystem) is what makes that
// reachable here: the arm stub forks a watcher that waits for the installer's
// own `handoff` and then writes the verdict, which is the real order of events.
//
// AND THE ANCHOR, in the same run, because the two claims are one finding. A
// severed or failed install must still have banked record_installed_version —
// it is what the NEXT run's migration gate reads, and it used to sit on the far
// side of the restart. Asserting it on the run that FAILS is what proves it was
// written before the point of no return rather than merely written somewhere.
func TestUnitsOnlyReportsAFailedRestartAndStillBanksTheAnchor(t *testing.T) {
	for _, goos := range forcedOSes {
		t.Run(goos, func(t *testing.T) {
			home := t.TempDir()
			stub := stubInitSystemFor(t, goos)
			seedMigrateCapableCLI(t, home)

			cmd := exec.Command("sh", installShPath(t))
			cmd.Dir = home
			cmd.Env = installShEnv(home, stub,
				"BURROWEE_UNITS_ONLY=1",
				"BURROWEE_VERSION=v0.9.9.2026.09.02",
				"STUB_GUARD_VERDICT=rolled-back",
				// Long enough for the stub watcher's 1s poll; this is the one
				// test in the package that wants reattach to actually wait.
				"REATTACH_CEILING=30",
				"REATTACH_INTERVAL=1",
			)
			out, err := cmd.CombinedOutput()
			if err == nil {
				t.Fatalf("%s: the install exited 0 after the guard reported a rollback — the host is not serving the build this run installed, and nothing said so:\n%s", goos, out)
			}
			assertContains(t, string(out),
				"the new build did not come up",
				"burrowee gateway service guard-status",
			)

			// Precondition: the verdict really did come from the phase file,
			// not from some other failure on the way there.
			if got := latestTxnPhase(t, home); got != "rolled-back" {
				t.Fatalf("%s: transaction phase = %q, want %q — the fixture did not exercise reattach's rollback arm", goos, got, "rolled-back")
			}

			anchor := filepath.Join(home, ".burrowee", "gateway", ".installed-version")
			b, readErr := os.ReadFile(anchor)
			if readErr != nil {
				t.Fatalf("%s: the version anchor was never written on a run that reached the handoff: %v", goos, readErr)
			}
			if got := strings.TrimSpace(string(b)); got != "v0.9.9.2026.09.02" {
				t.Errorf("%s: anchor = %q, want the version this run was handed — a stale anchor feeds the wrong floor into every later run's migration gate", goos, got)
			}
		})
	}
}

// TestBothPlatformsHandTheRestartToTheGuard is the test the original defect
// needed and no assertion could provide: the two branches must offer the SAME
// guarantee, checked side by side in one run, on one host.
//
// The guarantee used to be spelled as the advancing verb itself — Darwin's
// `kickstart -k`, Linux's `systemctl restart` — because install.sh issued it.
// It issues neither now: on this path (`burrowee gateway service install`,
// `doctor --fix`) the operator's session is routinely tunnelled through the
// daemon, so the advance is the guard's and the contract install.sh keeps is
// the HANDOFF. That contract has the same shape on both branches and the same
// way of going wrong — one platform quietly losing its step while the other
// keeps it, which is the defect this file was written for — so it is still
// checked as a pair, on one host, with `uname -s` forced.
//
// Two assertions, because either alone passes on a broken mode: the guard was
// handed to the init system (guardArmCallFor tells guard_arm's own bootstrap
// from any other on Darwin, where the verb alone cannot), and the transaction
// reached `handoff`, the token that means the restart is now the guard's
// problem. A mode that armed a guard and then exited without handing off
// leaves that guard to time out and roll a healthy host back.
//
// The verbs themselves are pinned where they are now issued:
// tools/guard-rollback.test.sh's t_guard_ok and t_guard_does_not_flap_the_units
// drive the real guard.sh against a real (fake) supervisor, per platform shape.
func TestBothPlatformsHandTheRestartToTheGuard(t *testing.T) {
	for _, goos := range forcedOSes {
		t.Run(goos, func(t *testing.T) {
			home := t.TempDir()
			stub := stubInitSystemFor(t, goos)
			seedMigrateCapableCLI(t, home)

			runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

			calls := readFile(t, filepath.Join(home, "stub-calls.log"))
			if !strings.Contains(calls, guardArmCallFor(goos)) {
				t.Errorf("%s: units-only never handed the guard to the init system (want %q) — `service install` and `doctor --fix` restart a gateway through the very connection the operator is running them over, unguarded; init calls:\n%s",
					goos, guardArmCallFor(goos), calls)
			}
			if got := latestTxnPhase(t, home); got != "handoff" {
				t.Errorf("%s: transaction phase = %q, want %q — the foreground did not hand the restart to the guard, so either nothing restarts or an armed guard times out and rolls a healthy host back", goos, got, "handoff")
			}
		})
	}
}
