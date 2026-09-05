// real_gateway_runner_test.go — THE ANCHOR THIS INSTALLER WRITES IS THE ANCHOR
// THE GATEWAY'S OWN RUNNER READS.
//
// WHY THIS FILE EXISTS AT ALL, AND WHY EVERY OTHER TEST HERE IS BLIND TO IT.
// The gateway does NOT take the shared ladder — tools/payload.sh's
// takes_shared_ladder is edge|cli|relay — so the runner assembled into a
// gateway kit is burrowee-git/gateway's OWN migrations/run.sh, which lives in a
// different repository and is nowhere in this one. Every other test in this
// package stages a FAKE runner (stageMigration, stageGwHomeProbe), which is
// right for asserting the hand-off and the ordering and useless for asserting
// agreement: a fake reads whatever the test told it to read.
//
// So the release repo moved the version anchor to $SYS_CONFIG_DIR and had no
// way to see that the gateway's runner was still reading
// $GW_HOME/.installed-version. The two halves ship as one kit and have to be
// changed in lockstep; this is the test that says whether they are.
//
// IT IS DELIBERATELY A CROSS-REPO TEST, and it skips rather than fails when the
// other repo's worktree is not on this machine — a release-repo contributor
// with no gateway checkout must not get a red suite over a file they cannot
// see. The skip names the exact path, so "skipped" is never mistaken for
// "passed".
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// gatewayLadderDir is the gateway repo's migrations/ for the project this
// change belongs to. Absolute by necessity: the two repos are siblings under
// the coding root and nothing in this module can resolve the other one.
const gatewayLadderDir = "/Users/Shared/Workstation/Coding/Burrowee/gateway/code/.worktrees/2026-09-05-gateway-install-hygiene/migrations"

// stageRealGatewayLadder copies the gateway repo's whole migrations/ beside a
// staged installer, or skips the test naming the path it wanted.
//
// The WHOLE directory, not just run.sh: a ledger row whose script is missing
// makes the runner refuse the entire run by design ("a mis-assembled kit must
// be impossible to run"), so a partial stage would test that refusal instead.
func stageRealGatewayLadder(t *testing.T, dir string) {
	t.Helper()
	entries, err := os.ReadDir(gatewayLadderDir)
	if err != nil {
		t.Skipf("the gateway repo's ladder is not on this machine (%s): this cross-repo "+
			"agreement test needs burrowee-git/gateway checked out at that path. "+
			"SKIPPED, not passed.", gatewayLadderDir)
	}
	mig := filepath.Join(dir, "migrations")
	if err := os.MkdirAll(mig, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sh") {
			continue
		}
		body, readErr := os.ReadFile(filepath.Join(gatewayLadderDir, e.Name()))
		if readErr != nil {
			t.Fatalf("read %s: %v", e.Name(), readErr)
		}
		if err := os.WriteFile(filepath.Join(mig, e.Name()), body, 0o755); err != nil {
			t.Fatalf("stage %s: %v", e.Name(), err)
		}
	}
}

// TestInstallShExportsTheConfigRootToTheRunner is the cheap half, and it has no
// cross-repo dependency: whatever the runner reads, it can only read
// $SYS_CONFIG_DIR if this installer tells it what that is. Both hand-off sites
// — the read-only --probe-pending fork and migrate_from_legacy's real run —
// must carry it, because a probe answering about a different root than the run
// it speaks for is worse than no probe.
//
// Mutation that reddens it: drop BURROWEE_SYSTEM_CONFIG_DIR from either call.
func TestInstallShExportsTheConfigRootToTheRunner(t *testing.T) {
	body, err := os.ReadFile(installShPath(t))
	if err != nil {
		t.Fatal(err)
	}
	var handoffs int
	// LOGICAL lines, not physical ones. migrate_from_legacy spells its hand-off
	// as a backslash-continued env prefix, so a physical-line scan sees
	// `GW_HOME="$GW_HOME" \` alone and reports a hand-off that carries nothing —
	// a false red that would teach the next reader to delete this test.
	for _, line := range logicalShellLines(string(body)) {
		if strings.HasPrefix(strings.TrimSpace(line), "#") || !strings.Contains(line, `GW_HOME="$GW_HOME"`) {
			continue
		}
		handoffs++
		if !strings.Contains(line, `BURROWEE_SYSTEM_CONFIG_DIR="$SYS_CONFIG_DIR"`) {
			t.Errorf("a runner hand-off does not export the config root, so the ladder "+
				"cannot find the anchor this installer writes:\n%s", strings.TrimSpace(line))
		}
	}
	if handoffs != 2 {
		t.Errorf("found %d runner hand-off sites, want 2 (the --probe-pending fork and "+
			"migrate_from_legacy) — if one was added or removed, this test's count is the "+
			"thing that should be updated deliberately", handoffs)
	}
}

// TestTheLadderAnchorIsWorldReadable is the half of the agreement that a
// same-machine test would otherwise never see, because this suite runs as ONE
// user who can read anything they wrote.
//
// The gateway runner reads the anchor UNPRIVILEGED — its anchor_path() tests
// `[ -f "$SYS_CONFIG_DIR/.installed-version" ]` and falls through to the legacy
// $GW_HOME path when that test fails. A `[ -f ]` on an unreadable-but-present
// file succeeds, but every read after it does not, and on the real host the
// file is root-owned while the reader is not. So a 0600 anchor is the worst
// available shape: no error, no refusal, just a ladder quietly gated on the
// wrong file.
//
// `tee` cannot be trusted to produce 0644. It takes its mode from the creating
// process's umask — root's is usually 022, but nothing stops a caller setting
// 077, and the CI machine's own login shell runs at 0002 — and on a re-write it
// leaves the existing mode alone entirely. Hence the explicit chmod, and hence
// this assertion on the RESULT rather than on the call.
//
// Mutation that reddens it: drop the `run_root chmod 0644` from
// record_installed_version and run the suite under `umask 077`.
func TestTheLadderAnchorIsWorldReadable(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)

	// A hostile umask, deliberately: the point is that the mode is STATED and
	// not inherited. runStagedWithUmask drives install.sh under a chosen umask
	// (system_tree_test.go), which is the only way to make this assertion able
	// to fail on a developer machine whose umask is already 022.
	out, err := runStagedWithUmask(t, installShPath(t), home, home, stub, "077",
		"BURROWEE_UNITS_ONLY=1",
		"BURROWEE_VERSION=gateway/v0.3.0.2026.09.05.abcdef12",
	)
	if err != nil {
		t.Fatalf("units-only failed under umask 077: %v\n%s", err, out)
	}

	anchor := ladderAnchorPath(home)
	st, statErr := os.Stat(anchor)
	if statErr != nil {
		t.Fatalf("no ladder anchor at %s: %v\n%s", anchor, statErr, out)
	}
	if got := st.Mode().Perm(); got != 0o644 {
		t.Errorf("ladder anchor %s is mode %04o, want 0644 — the gateway runner reads it "+
			"unprivileged and silently falls back to the legacy $GW_HOME anchor when it "+
			"cannot, so a tight mode here is a migration gate nobody can see is broken",
			anchor, got)
	}

	// And the directory it sits in has to be traversable for the same reader.
	dst, statErr := os.Stat(filepath.Dir(anchor))
	if statErr != nil {
		t.Fatal(statErr)
	}
	if got := dst.Mode().Perm(); got&0o005 != 0o005 {
		t.Errorf("%s is mode %04o — an unprivileged reader cannot traverse into it, so the "+
			"anchor's own mode does not matter", filepath.Dir(anchor), got)
	}
}

// TestTheRealGatewayRunnerReadsTheAnchorThisInstallerWrites is the agreement
// itself, end to end: a units-only install writes the anchor, and the gateway
// repo's REAL runner — the one that ships in the kit — is then asked what
// version it sees and where it read it from.
//
// --probe-pending is the vehicle because it is READ-ONLY by contract (the
// runner's own header: "Decide the ladder and report what a real run would do")
// and answers 10 pending / 11 nothing pending / 12 could not evaluate. The
// recorded version is deliberately far above every ledger target, so the
// numeric gate retires every rung and NOT ONE rung's --applies probe is
// invoked: the run is inert, which is what lets a real ladder be driven inside
// a sandbox at all.
//
// The environment is the five names migrate_from_legacy hands the runner, and
// TestInstallShExportsTheConfigRootToTheRunner above is what keeps that list
// from drifting into a test agreeing with itself.
//
// Mutation that reddens it: point record_installed_version back at $GW_HOME
// (the runner then reports the version as unrecorded, or reads it from the home
// tree), or revert the gateway runner's anchor_path to $GW_HOME only.
func TestTheRealGatewayRunnerReadsTheAnchorThisInstallerWrites(t *testing.T) {
	const version = "v9.9.9.2026.09.05.abcdef12"

	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)

	// The anchor, written by the installer under test.
	runInstallSh(t, home, stub,
		"BURROWEE_UNITS_ONLY=1",
		"BURROWEE_VERSION=gateway/"+version,
	)
	if got := installedVersion(t, home); got != version {
		t.Fatalf("precondition: the installer did not write the anchor at %s (got %q) — "+
			"this test would then be measuring the runner against nothing",
			ladderAnchorPath(home), got)
	}

	// The real ladder, staged the way a kit stages it: beside an installer.
	bundle := t.TempDir()
	stageRealGatewayLadder(t, bundle) // skips the test when the gateway repo is absent

	cmd := exec.Command("sh", filepath.Join(bundle, "migrations", "run.sh"), "--probe-pending")
	cmd.Dir = home
	cmd.Env = []string{
		"HOME=" + home,
		"PATH=" + stub + ":/usr/bin:/bin",
		"STUB_LOG=" + filepath.Join(home, "stub-calls.log"),
		// The five migrate_from_legacy passes, and nothing else.
		"GW_HOME=" + filepath.Join(home, ".burrowee", "gateway"),
		"PREFIX=" + filepath.Dir(binDir(home)),
		"BURROWEE_SYSTEM_CONFIG_DIR=" + sysConfigDir(home),
		"BURROWEE_SYSTEM_DATA_DIR=" + sysDataDir(home),
		"SUDO=sudo -n",
	}
	out, err := cmd.CombinedOutput()
	t.Logf("gateway runner --probe-pending:\n%s", out)

	// 11 = nothing pending, which is the only honest answer for a host recorded
	// at 9.9.9 against a ladder whose top target is far below it. 12 ("could not
	// evaluate") is the answer a runner gives when it cannot read the anchor at
	// all, so it is precisely the failure this test is here to catch.
	code := 0
	if err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("running the gateway runner: %v", err)
		}
		code = ee.ExitCode()
	}
	if code != 11 {
		t.Errorf("gateway runner --probe-pending exited %d, want 11 (nothing pending). "+
			"12 means it could not evaluate — i.e. it did not find the anchor this "+
			"installer wrote.", code)
	}

	got := string(out)
	if !strings.Contains(got, "installed version "+version) {
		t.Errorf("the gateway runner does not see the version this installer recorded (%s). "+
			"The release half and the gateway half of this change are NOT in lockstep.", version)
	}
	wantFrom := "(read from " + ladderAnchorPath(home) + ")"
	if !strings.Contains(got, wantFrom) {
		t.Errorf("the gateway runner did not read the anchor from %s — the two halves name "+
			"different files, which is the whole defect this test exists for.\nwant substring: %s",
			ladderAnchorPath(home), wantFrom)
	}
	if strings.Contains(got, filepath.Join(home, ".burrowee", "gateway", ".installed-version")) {
		t.Errorf("the gateway runner read the anchor out of the operator's home tree:\n%s", got)
	}
}

// logicalShellLines joins backslash-continued physical lines into the single
// statement the shell sees.
func logicalShellLines(body string) []string {
	var out []string
	var cur strings.Builder
	for _, line := range strings.Split(body, "\n") {
		if strings.HasSuffix(line, "\\") {
			cur.WriteString(strings.TrimSuffix(line, "\\"))
			cur.WriteString(" ")
			continue
		}
		cur.WriteString(line)
		out = append(out, cur.String())
		cur.Reset()
	}
	if cur.Len() > 0 {
		out = append(out, cur.String())
	}
	return out
}
