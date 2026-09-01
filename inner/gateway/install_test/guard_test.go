// guard_test.go — the two seams the guard's post-success work (Task 10)
// depends on, tested from THIS repo's side of the boundary.
//
// guard.sh's own dynamic behaviour — a real run against a fake host, on both
// platform shapes — is covered end-to-end by tools/guard-rollback.test.sh's
// t_guard_ok / t_guard_rolls_back / t_guard_ok_advances_updater /
// t_guard_ok_sweeps_stale_bins / t_guard_deadline_exceeded and by
// tools/guard-installer-death.test.sh, the regression test for the reported
// bug. This file does NOT re-run guard.sh (TestFreshInstallHandsTheRestartToTheGuard
// in daemon_advance_test.go already explains why that would either race a
// process the suite's stubs never actually spawn, or assert a promise this
// script's foreground no longer makes). What belongs here instead:
//
//  1. install.sh's half of the seam that lets the guard find the kept
//     installer at all: the manifest it writes must carry gw_home=, because
//     the guard runs under launchd/systemd with no reliable $HOME of its own
//     to resolve $GW_HOME from.
//  2. A source-level guard on guard.sh's own most important invariant — it
//     must never bootout the serve label — anchored so that Task 10's
//     legitimate addition (bootout/bootstrap/enable/kickstart of the
//     UPDATER label, which nothing routes through and is safe to unload)
//     can never be mistaken for the one this whole plan exists to remove.
//     Mirrors tools/install-no-bootout.test.sh's own style, which scans
//     install.sh for the identical reason; guard.sh had no static net of its
//     own before this.
package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// latestTxnManifest reads the manifest of the transaction install.sh most
// recently created under sysDataDir(home)/install/ — same selection rule as
// latestTxnPhase, just a different file in the same directory.
func latestTxnManifest(t *testing.T, home string) string {
	t.Helper()
	root := filepath.Join(sysDataDir(home), "install")
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("read transaction root %s: %v", root, err)
	}
	if len(entries) == 0 {
		t.Fatalf("no transaction directory under %s — txn_begin never ran", root)
	}
	last := entries[len(entries)-1].Name()
	return readFile(t, filepath.Join(root, last, "manifest"))
}

// TestFreshInstallRecordsGwHomeForTheGuard is Correction 1's install.sh half:
// snapshot_take must write gw_home= into the manifest, or the guard's
// post-success sweep (guard.sh's sweep_stale_bins_via_kept_installer) has no
// way to find $GW_HOME/install.sh and silently no-ops on every real host.
func TestFreshInstallRecordsGwHomeForTheGuard(t *testing.T) {
	for _, goos := range forcedOSes {
		t.Run(goos, func(t *testing.T) {
			home := t.TempDir()
			stub := stubInitSystemFor(t, goos)
			staging := t.TempDir()
			seedDummyBins(t, staging)

			if out, err := runStaged(t, installShPath(t), staging, home, stub); err != nil {
				t.Fatalf("fresh install failed: %v\n%s", err, out)
			}

			manifest := latestTxnManifest(t, home)
			if !strings.Contains(manifest, "gw_home=") {
				t.Errorf("manifest carries no gw_home= — the guard's post-success sweep has no way "+
					"to find the kept installer at $GW_HOME/install.sh:\n%s", manifest)
			}
		})
	}
}

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
