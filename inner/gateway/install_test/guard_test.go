// guard_test.go — source-level regression guards for guard.sh's post-success
// work (Task 10), from THIS repo's side of the boundary.
//
// guard.sh's own dynamic behaviour — a real run against a fake host, on both
// platform shapes — is covered end-to-end by tools/guard-rollback.test.sh's
// t_guard_ok / t_guard_rolls_back / t_guard_ok_advances_updater /
// t_guard_ok_sweeps_stale_bins / t_guard_deadline_exceeded and by
// tools/guard-installer-death.test.sh, the regression test for the reported
// bug. This file does NOT re-run guard.sh (TestFreshInstallHandsTheRestartToTheGuard
// in daemon_advance_test.go already explains why that would either race a
// process the suite's stubs never actually spawn, or assert a promise this
// script's foreground no longer makes). What belongs here instead is a
// static, line-anchored net on guard.sh's own source for its two sharpest
// invariants — mirroring tools/install-no-bootout.test.sh's own style, which
// scans install.sh for a similar reason; guard.sh had no static net of its
// own before this:
//
//  1. It must never source a per-user path as root (review round 1,
//     CRITICAL: the first version of this file sourced $GW_HOME/install.sh,
//     writable by the invoking operator, or anything running as them, at any
//     time after the install finishes — sourcing that as root turned
//     "compromise one non-root account" into unattended root code
//     execution). It must source only the root-secure copy
//     ensure_root_exec_surface places at $BIN_DIR/install.sh.
//  2. It must never bootout the serve label — the reported bug's exact
//     mechanism.
package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// guardShSource reads inner/gateway/guard.sh, this repo's copy — the same
// file the plist/unit guard_arm renders points at before it is ever copied
// to $_libexec_dir/gateway-guard.
func guardShSource(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "guard.sh"))
	if err != nil {
		t.Fatalf("read guard.sh: %v", err)
	}
	return string(b)
}

// TestGuardSweepsOnlyTheRootSecureInstaller is the regression guard for
// review round 1's CRITICAL finding: the guard is already uid 0, and
// sourcing any path that a non-root account (or anything running as one) can
// write turns a single compromised operator account into unattended root
// code execution on the next successful restart — including an
// updater-triggered one. $GW_HOME resolves from the INVOKING OPERATOR's
// $HOME (install.sh:194) and keep_installer_copy writes it with a plain
// `cp`, never run_root (install.sh:1179) — exactly such a path. The only
// copy safe to source as root is $BIN_DIR/install.sh, which
// ensure_root_exec_surface places root-owned and verify_root_exec_surface
// proves non-root-unwritable all the way to / on every install.
//
// Comment lines are skipped rather than banning the substring outright: this
// file's own header, and guard.sh's own comments, explain the invariant in
// prose using "$GW_HOME" — banning the literal substring everywhere would
// make the documentation of the fix fail the check for the fix.
func TestGuardSweepsOnlyTheRootSecureInstaller(t *testing.T) {
	src := guardShSource(t)

	sawRootSecureSource := false
	for _, line := range strings.Split(src, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") {
			continue
		}
		if strings.Contains(line, "$GW_HOME") || strings.Contains(line, "gw_home=") {
			t.Errorf("guard.sh references a per-user $GW_HOME path outside a comment — that path "+
				"is writable by the invoking operator (or anything running as them) at any time "+
				"after the install finishes, and this guard runs as root: %q", line)
		}
		if strings.Contains(line, `"$BIN_DIR/install.sh"`) {
			sawRootSecureSource = true
		}
	}
	if !sawRootSecureSource {
		t.Error(`guard.sh never sources "$BIN_DIR/install.sh" — the root-secure copy ` +
			"ensure_root_exec_surface places; this comparison would otherwise pass vacuously " +
			"on a guard that sources nothing at all")
	}
}

// TestGuardNeverUnsupervisesTheServeLabel is the source-level regression
// guard for the reported bug's exact mechanism: `bootout` unloads a job, an
// unloaded job is supervised by nothing, and a shell that dies between a
// bootout and the bootstrap that was going to follow it — a tunnelled
// operator's session dying exactly because the bootout killed the connection
// it rode in on — leaves the daemon stopped forever. guard.sh's own restart
// must always be the launchd kickstart / systemd restart form, on both
// platform branches, and never a bootout/stop of the SERVE label.
//
// The check is line-based, not a single regexp, so that Task 10's own
// legitimate addition — the updater advance, which DOES bootout and restart
// $LABEL.updater — cannot be mistaken for a regression here: every pattern
// below is anchored to the BARE label/unit, with no ".updater" suffix.
func TestGuardNeverUnsupervisesTheServeLabel(t *testing.T) {
	src := guardShSource(t)

	sawDarwinKickstart := false
	sawLinuxRestart := false
	for _, line := range strings.Split(src, "\n") {
		if strings.Contains(line, `bootout "system/$LABEL"`) {
			t.Errorf("guard.sh boots out the bare serve label — an unloaded job is supervised "+
				"by nothing, which is the exact bug this file exists to fix: %q", line)
		}
		if strings.Contains(line, `kickstart -k "system/$LABEL"`) {
			sawDarwinKickstart = true
		}
		if strings.Contains(line, `stop "$UNIT"`) || strings.Contains(line, `disable "$UNIT"`) {
			t.Errorf("guard.sh unsupervises the bare Linux serve unit: %q", line)
		}
		if strings.Contains(line, `restart "$UNIT"`) {
			sawLinuxRestart = true
		}
	}
	if !sawDarwinKickstart {
		t.Error(`guard.sh contains no kickstart -k "system/$LABEL" — this comparison would ` +
			"otherwise pass vacuously on a guard that never restarts the Darwin serve label at all")
	}
	if !sawLinuxRestart {
		t.Error(`guard.sh contains no restart "$UNIT" — this comparison would otherwise pass ` +
			"vacuously on a guard that never restarts the Linux serve unit at all")
	}
}
