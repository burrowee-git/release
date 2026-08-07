// Package install_test: the migration gate — the pre-flight that must refuse
// BEFORE install.sh writes anything, and the version anchor that must not be
// recorded for a migration that did not actually complete.
//
// Every assertion here is about a host that ends up WORSE than if the install
// had never been attempted: units on disk that launchd will bootstrap at the
// next reboot against an empty system config root, or a version number that
// gates a pending migration off forever. Both end in the daemon minting a fresh
// relay_ed.key and the node re-registering as a NEW node — losing its console
// pairing, targets and domains.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
)

// coreUnitPath is the sandboxed core system unit for this platform.
func coreUnitPath(home string) string {
	if runtime.GOOS == "darwin" {
		return filepath.Join(launchdDir(home), "com.burrowee.gateway.plist")
	}
	return filepath.Join(systemdDir(home), "burrowee-gateway.service")
}

// updaterUnitPath is the sandboxed updater system unit for this platform.
func updaterUnitPath(home string) string {
	if runtime.GOOS == "darwin" {
		return filepath.Join(launchdDir(home), "com.burrowee.gateway.updater.plist")
	}
	return filepath.Join(systemdDir(home), "burrowee-gateway-updater.service")
}

// assertNoUnitsWritten fails when either system unit exists.
func assertNoUnitsWritten(t *testing.T, home string) {
	t.Helper()
	for _, p := range []string{coreUnitPath(home), updaterUnitPath(home)} {
		if _, err := os.Stat(p); err == nil {
			t.Errorf("a system unit was written despite the refusal: %s\n%s", p, readFile(t, p))
		}
	}
}

// stageFaithfulRunner plants a migrations/run.sh beside a staged installer that
// reproduces the REAL runner's opening move: cli_supports_migrate against the
// INSTALLED burrowee-gateway-cli, refusing with exit 1 when the verb is absent
// (migrations/run.sh:215-218, 264-271). It appends to logPath only once past
// that gate, so an empty log means "the runner refused", not "never invoked".
//
// The generic stageMigration stub cannot show this defect: it succeeds
// unconditionally, so a broken install.sh would exit 0 and the failure would
// read as a missing refusal rather than as units-written-too-early.
func stageFaithfulRunner(t *testing.T, dir, logPath string) {
	t.Helper()
	mig := filepath.Join(dir, "migrations")
	if err := os.MkdirAll(mig, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\n" +
		"_cli=\"${PREFIX:-$HOME/.local}/bin/burrowee-gateway-cli\"\n" +
		"if [ ! -x \"$_cli\" ] || ! \"$_cli\" migrate --help >/dev/null 2>&1; then\n" +
		"  echo \"migrate: $_cli does not support 'migrate' — refusing to start, nothing has been touched.\" >&2\n" +
		"  exit 1\n" +
		"fi\n" +
		"echo RAN >> " + shQuote(logPath) + "\n" +
		"echo migration-ran\nexit 2\n"
	if err := os.WriteFile(filepath.Join(mig, "run.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

// installedVersion returns the recorded ladder anchor, or "" when absent.
func installedVersion(t *testing.T, home string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(home, ".burrowee", "gateway", ".installed-version"))
	if os.IsNotExist(err) {
		return ""
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(b))
}

// ---------------------------------------------------------------------------
// C1 — the 0.1.115 host.
// ---------------------------------------------------------------------------

// TestUpdateRefusesBeforeAnyWriteWhenTheCLICannotMigrate is the release
// blocker, simulated end to end: a live 0.1.115 host whose installed
// burrowee-gateway-cli has no `migrate` verb (it arrived after 0.1.115), being
// updated by the console-push path with a bundle that carries a migration.
//
// The old order was: swap the binaries → keep the installer copy → render the
// ROOT-SCHEME units into /Library/LaunchDaemons → run the migration → the
// runner's cli_supports_migrate probe fails → exit 1. The caller sees a failed
// update and no recorded version, so it reports failure and moves on. But the
// units are on disk, nothing removes them, and at the next reboot launchd
// bootstraps a ROOT daemon against an empty system config root: it mints a
// fresh relay_ed.key and the node re-registers as a NEW node.
//
// The invariant this pins: no unit file is written and no binary is swapped
// unless the migration is known to be able to complete.
//
// BOTH the fixed and the broken shape exit non-zero here, because the runner
// stub refuses exactly as the real one does. That is deliberate: the exit
// status was never the problem — the caller already reported failure. What
// separates the two is whether the refusal arrived before or after the writes,
// so the units, the binaries and the runner log are the assertions that matter.
func TestUpdateRefusesBeforeAnyWriteWhenTheCLICannotMigrate(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := home + "/.local/bin"
	logPath := filepath.Join(t.TempDir(), "migration.log")

	// The live 0.1.115 host: every binary at 0.1.115, and its cli refuses
	// `migrate`.
	seedInstalled(t, binDir, withCLI(allBinsContent("v0.1.115"), cliWithoutMigrate))

	// The pushed bundle. Its cli ALSO lacks the verb — that is what makes this
	// the refusal case rather than the everyday one; a real 0.2.x bundle ships
	// a cli that has it, which is why placing the cli (see
	// TestUpdateModeExcludesOnlyTheUpdaterBinary) fixes the field scenario and
	// this pre-flight is the belt to that braces.
	staged := withCLI(allBinsContent("v0.2.0"), cliWithoutMigrate)
	stageDir := stageBundle(t, staged)
	script := stageInstaller(t, stageDir)
	stageFaithfulRunner(t, stageDir, logPath)

	out, err := runStagedArgs(t, script, stageDir, home, stub,
		[]string{"--version", "0.2.0"}, "BURROWEE_UPDATE=1")
	if err == nil {
		t.Fatalf("update succeeded on a host whose cli cannot migrate:\n%s", out)
	}
	assertContains(t, out, "burrowee-gateway-cli migrate", "nothing has been touched")

	// 1. No unit file written — the whole point.
	assertNoUnitsWritten(t, home)

	// 2. No binary swapped: every one still at 0.1.115.
	for _, b := range allBins {
		want := "v0.1.115"
		if b == "burrowee-gateway-cli" {
			want = cliWithoutMigrate
		}
		if got := readInstalled(t, binDir, b); got != want {
			t.Errorf("%s was swapped despite the refusal: got %q", b, got)
		}
	}

	// 3. The runner was never even started, so nothing was stopped.
	if got := migrationLog(t, logPath); got != "" {
		t.Errorf("the migration runner ran despite the refusal:\n%s", got)
	}

	// 4. No version recorded, and no leftover backup files.
	if v := installedVersion(t, home); v != "" {
		t.Errorf("version recorded despite the refusal: %q", v)
	}
	entries, err := os.ReadDir(binDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.Contains(e.Name(), ".bak-") {
			t.Errorf("backup left behind by the refusal: %s", e.Name())
		}
	}
}

// TestUnitsOnlyRefusesBeforeAnyWriteWhenTheCLICannotMigrate is the same defect
// on the mode that reaches it most easily. `burrowee gateway service install`
// re-runs the copy kept at $GW_HOME with BURROWEE_UNITS_ONLY=1: it places NO
// binaries at all, so whatever cli is on disk is the one the runner will probe,
// and render_units runs before the migration. On a 0.1.115 host that is
// root-scheme units on disk, a migration that never ran, and exit 1.
func TestUnitsOnlyRefusesBeforeAnyWriteWhenTheCLICannotMigrate(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	bundle := t.TempDir()
	script := stageInstaller(t, bundle)
	logPath := filepath.Join(t.TempDir(), "migration.log")
	stageMigration(t, bundle, logPath, 0)

	binDir := filepath.Join(home, ".local", "bin")
	seedInstalled(t, binDir, map[string]string{"burrowee-gateway-cli": cliWithoutMigrate})

	out, err := runStaged(t, script, home, home, stub, "BURROWEE_UNITS_ONLY=1")
	if err == nil {
		t.Fatalf("units-only succeeded on a host whose cli cannot migrate:\n%s", out)
	}
	assertNoUnitsWritten(t, home)
	if got := migrationLog(t, logPath); got != "" {
		t.Errorf("the migration runner ran despite the refusal:\n%s", got)
	}
	// Not even a legacy-teardown or supervisor call: the refusal is the first
	// thing this mode does.
	if b, readErr := os.ReadFile(filepath.Join(home, "stub-calls.log")); readErr == nil && len(b) > 0 {
		t.Errorf("supervisor calls issued despite the refusal:\n%s", b)
	}
}

// TestFreshInstallRefusesBeforeAnyWriteWhenTheCLICannotMigrate: the curl-pipe
// path places the cli itself, so its pre-flight asks the STAGED one. A bundle
// carrying a migration but a cli that cannot run it is internally inconsistent,
// and installing half of it onto a legacy host is the same node-identity loss.
func TestFreshInstallRefusesBeforeAnyWriteWhenTheCLICannotMigrate(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	bundle := t.TempDir()
	seedDummyBins(t, bundle)
	if err := os.WriteFile(filepath.Join(bundle, "burrowee-gateway-cli"), []byte(cliWithoutMigrate), 0o755); err != nil {
		t.Fatal(err)
	}
	script := stageInstaller(t, bundle)
	logPath := filepath.Join(t.TempDir(), "migration.log")
	stageMigration(t, bundle, logPath, 0)

	out, err := runStaged(t, script, bundle, home, stub)
	if err == nil {
		t.Fatalf("fresh install succeeded with a cli that cannot migrate:\n%s", out)
	}
	assertNoUnitsWritten(t, home)
	if _, statErr := os.Stat(filepath.Join(home, ".local", "bin", "burrowee-gateway")); statErr == nil {
		t.Errorf("a binary was installed despite the refusal")
	}
	if got := migrationLog(t, logPath); got != "" {
		t.Errorf("the migration runner ran despite the refusal:\n%s", got)
	}
}

// TestUpdateProceedsWhenTheStagedCLICarriesTheVerb is the other side of the
// gate, and the one that keeps it from being a blanket refusal: the same 0.1.115
// host, updated with a real 0.2.x bundle, must migrate and complete. The cli on
// disk still lacks the verb when install.sh starts — placing the staged one is
// what makes the runner's probe pass.
func TestUpdateProceedsWhenTheStagedCLICarriesTheVerb(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := home + "/.local/bin"
	logPath := filepath.Join(t.TempDir(), "migration.log")

	seedInstalled(t, binDir, withCLI(allBinsContent("v0.1.115"), cliWithoutMigrate))
	staged := withCLI(allBinsContent("v0.2.0"), cliWithMigrate)
	script, stageDir := stagedUpdateBundle(t, staged, logPath, 2) // "migrations ran"

	out, err := runStagedArgs(t, script, stageDir, home, stub,
		[]string{"--version", "0.2.0"}, "BURROWEE_UPDATE=1")
	if err != nil {
		t.Fatalf("update failed with a migrate-capable bundle: %v\n%s", err, out)
	}
	if got := readInstalled(t, binDir, "burrowee-gateway-cli"); got != cliWithMigrate {
		t.Errorf("the staged cli was not placed: %q", got)
	}
	if migrationLog(t, logPath) == "" {
		t.Fatalf("the migration never ran:\n%s", out)
	}
	if v := installedVersion(t, home); v != "0.2.0" {
		t.Errorf("installed-version = %q, want 0.2.0", v)
	}
}

// ---------------------------------------------------------------------------
// H7 — the deferred migration must not record a version.
// ---------------------------------------------------------------------------

// TestUpdateDoesNotRecordTheVersionWhenTheMigrationIsDeferred: on a slot owned
// by another user, update mode prints "not migrating either" and skips the
// runner — but it used to fall through and write .installed-version anyway.
//
// That is not a cosmetic inconsistency. The runner consults a migration's own
// --applies probe ONLY when no version is recorded; with one recorded, the
// numeric gate is the sole authority. Recording the new version for a rung that
// never ran gates it off permanently, with the legacy tree sitting untouched
// beside it — a second, independent route to C1's outcome.
func TestUpdateDoesNotRecordTheVersionWhenTheMigrationIsDeferred(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := home + "/.local/bin"
	logPath := filepath.Join(t.TempDir(), "migration.log")

	seedForeignUnit(t, home)
	seedInstalled(t, binDir, withCLI(allBinsContent("v1-content"), cliWithMigrate))
	staged := withCLI(allBinsContent("v1-content"), cliWithMigrate)
	staged["burrowee-gateway"] = "gw-v2-content"
	script, stageDir := stagedUpdateBundle(t, staged, logPath, 0)

	out, err := runStagedArgs(t, script, stageDir, home, stub,
		[]string{"--version", "0.2.7"}, "BURROWEE_UPDATE=1")
	if err != nil {
		t.Fatalf("install.sh update failed: %v\n%s", err, out)
	}

	// Precondition: the migration really was skipped (otherwise this test would
	// pass for the wrong reason).
	if got := migrationLog(t, logPath); got != "" {
		t.Fatalf("migrated while another user owns the slot:\n%s", got)
	}
	if v := installedVersion(t, home); v != "" {
		t.Errorf("version recorded for a migration that never ran: %q", v)
	}
	assertContains(t, out, "not migrating either", "installed version is not recorded")

	// The binary swap is independent of the deferral and must still complete.
	if got := readInstalled(t, binDir, "burrowee-gateway"); got != "gw-v2-content" {
		t.Errorf("binary swap should still succeed: got %q", got)
	}
}

// ---------------------------------------------------------------------------
// run.sh exit 3 — "migrated but not recorded".
// ---------------------------------------------------------------------------

// TestUpdateDoesNotRecordTheVersionOnAnUnrecordedMigration: exit 3 means the
// migration ran (so the gateway is stopped, exactly as for 2) but its receipt
// could not be written. The receipt is what makes a completed migration a
// no-op on re-run; with it missing, the version anchor is the only remaining
// gate. Writing it would silently convert a receipt-gated, re-runnable
// migration into a version-gated never-again one — so the anchor is withheld
// and the operator is told why.
func TestUpdateDoesNotRecordTheVersionOnAnUnrecordedMigration(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := home + "/.local/bin"
	logPath := filepath.Join(t.TempDir(), "migration.log")

	seedInstalled(t, binDir, withCLI(allBinsContent("v1-content"), cliWithMigrate))
	staged := withCLI(allBinsContent("v1-content"), cliWithMigrate)
	staged["burrowee-gateway"] = "gw-v2-content"
	script, stageDir := stagedUpdateBundle(t, staged, logPath, 3)

	out, err := runStagedArgs(t, script, stageDir, home, stub,
		[]string{"--version", "0.2.0"}, "BURROWEE_UPDATE=1")
	if err != nil {
		t.Fatalf("exit 3 from the runner must not fail the update: %v\n%s", err, out)
	}
	if v := installedVersion(t, home); v != "" {
		t.Errorf("version recorded for an unrecorded migration: %q", v)
	}
	// Reported distinctly from a clean exit 2, and still reported as stopped.
	assertContains(t, out, "receipt could not be written", "stopped the gateway")
	if got := lastLineWithPrefix(out, "BURROWEE_CHANGED="); got == "" {
		t.Errorf("BURROWEE_CHANGED line missing:\n%s", out)
	}
}

// ---------------------------------------------------------------------------
// H8 — fresh install records the ladder anchor.
// ---------------------------------------------------------------------------

// TestFreshInstallRecordsTheVersion: the anchor used to be written from exactly
// one place platform-wide (update mode, and only with --version), so a host
// installed fresh had none and reached every future rung through the runner's
// --applies fallback — the path the runner's own header calls exceptional. Any
// migration that cannot recognise its own precondition structurally would then
// silently never run.
//
// The prefix strip is not cosmetic. The outer bootstrap passes the resolved
// TAG, which is "<component>/v<semver>…"; the runner reads dot-separated fields
// as numbers, so "gateway/v0" is non-numeric and the whole version resolves to
// 0.0.0 — making a freshly-installed 0.2.x host look older than every migration
// ever written and re-running all of them.
func TestFreshInstallRecordsTheVersion(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)

	cmd := exec.Command("sh", installShPath(t))
	cmd.Dir = staging
	cmd.Env = installShEnv(home, stub, "BURROWEE_VERSION=gateway/v0.2.0.2026.08.06.d0d79ec6")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("fresh install failed: %v\n%s", err, out)
	}

	if got, want := installedVersion(t, home), "v0.2.0.2026.08.06.d0d79ec6"; got != want {
		t.Errorf("installed-version = %q, want %q (the component prefix must be stripped)", got, want)
	}
}

// TestUpdateFallsBackToTheBootstrapVersion: the outer bootstrap re-runs this
// script in update mode (the `--force` full reinstall) carrying the resolved
// tag in BURROWEE_VERSION and no argv of its own, so that path recorded no
// anchor at all. Argv still wins where both are present.
func TestUpdateFallsBackToTheBootstrapVersion(t *testing.T) {
	for name, tc := range map[string]struct {
		args      []string
		env, want string
	}{
		"env only":  {nil, "gateway/v0.2.0.2026.08.06.d0d79ec6", "v0.2.0.2026.08.06.d0d79ec6"},
		"argv wins": {[]string{"--version", "0.2.1"}, "gateway/v0.2.0", "0.2.1"},
		"neither":   {nil, "", ""},
	} {
		t.Run(name, func(t *testing.T) {
			home := t.TempDir()
			stub := stubInitSystem(t)
			binDir := home + "/.local/bin"

			seedInstalled(t, binDir, withCLI(allBinsContent("v1-content"), cliWithMigrate))
			staged := withCLI(allBinsContent("v1-content"), cliWithMigrate)
			staged["burrowee-gateway"] = "gw-v2-content"
			stageDir := stageBundle(t, staged)

			env := []string{"BURROWEE_UPDATE=1"}
			if tc.env != "" {
				env = append(env, "BURROWEE_VERSION="+tc.env)
			}
			runUpdate(t, stageDir, home, stub, env, tc.args...)

			if got := installedVersion(t, home); got != tc.want {
				t.Errorf("installed-version = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestFreshInstallWithoutAVersionRecordsNothing: a hand-invoked inner installer
// gets no BURROWEE_VERSION. Inventing one would be worse than none — a wrong
// anchor gates real migrations off, whereas an absent one falls back to each
// migration's own --applies probe.
func TestFreshInstallWithoutAVersionRecordsNothing(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)

	cmd := exec.Command("sh", installShPath(t))
	cmd.Dir = staging
	cmd.Env = installShEnv(home, stub)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("fresh install failed: %v\n%s", err, out)
	}
	if v := installedVersion(t, home); v != "" {
		t.Errorf("a version was invented with none supplied: %q", v)
	}
}

// ---------------------------------------------------------------------------
// MEDIUM — the SUDO handed to the runner follows install.sh's own tty policy.
// ---------------------------------------------------------------------------

// TestMigrationGetsANonPromptingSudoWithoutATty: install.sh's own run_root uses
// a prompting `sudo` only when a controlling tty exists and `sudo -n`
// otherwise, but it handed the runner a bare `sudo` regardless. The documented
// flow is `curl … | sh`, where stdin is the pipe: that bare sudo dies on "no
// tty present and no askpass program" — AFTER the runner has stopped the
// gateway, and with none of run_root's hint text.
//
// Setsid detaches the child from the controlling terminal, so /dev/tty is
// genuinely unopenable and has_tty is false no matter where the suite runs.
func TestMigrationGetsANonPromptingSudoWithoutATty(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	bundle := t.TempDir()
	script := stageInstaller(t, bundle)
	logPath := filepath.Join(t.TempDir(), "migration.log")
	seedMigrateCapableCLI(t, home)
	stageMigration(t, bundle, logPath, 0)

	cmd := exec.Command("sh", script)
	cmd.Dir = home
	cmd.Env = installShEnv(home, stub, "BURROWEE_UNITS_ONLY=1")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("install.sh failed: %v\n%s", err, out)
	}

	log := migrationLog(t, logPath)
	if log == "" {
		t.Fatal("the migration never ran")
	}
	assertContains(t, log, "SUDO=sudo -n")
}

// ---------------------------------------------------------------------------
// MEDIUM — the first-run probe must test STATE, not a directory this script
// itself created.
// ---------------------------------------------------------------------------

// TestFreshInstallPromptsSetupOnAVirginHost: keep_installer_copy creates
// $GW_HOME and writes install.sh + migrations/ into it, and the old probe then
// asked whether $GW_HOME was non-empty. It always is, by the time it is asked.
// So a genuinely virgin host printed "gateway already set up — skipping setup"
// and the blob + PIN step never ran: the operator installed a gateway that
// silently never enrolled.
//
// With no usable /dev/tty the installer prints the next step instead of
// prompting, so that line is what a virgin host must produce.
func TestFreshInstallPromptsSetupOnAVirginHost(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)

	cmd := exec.Command("sh", installShPath(t))
	cmd.Dir = staging
	cmd.Env = installShEnv(home, stub)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("fresh install failed: %v\n%s", err, out)
	}

	if strings.Contains(string(out), "already set up") {
		t.Errorf("virgin host reported as already set up — setup was skipped:\n%s", out)
	}
	assertContains(t, string(out), "next: burrowee gateway bootstrap")

	// And the installer copy really is sitting in $GW_HOME: without it the test
	// would pass simply because the directory was empty, which is the shape the
	// bug needs to be reproduced against.
	if _, statErr := os.Stat(filepath.Join(home, ".burrowee", "gateway", "install.sh")); statErr != nil {
		t.Fatalf("the installer copy is missing, so this test is not exercising the bug: %v", statErr)
	}
}

// TestFreshInstallSkipsSetupWhenStateExists is the half the probe must not
// lose: an enrolled host must never be re-prompted for a setup blob. Both
// layouts count — the pre-0.2.0 per-user tree, and the SYSTEM roots a migrated
// or root-installed host keeps its identity in, where $GW_HOME holds nothing
// but the installer copy.
func TestFreshInstallSkipsSetupWhenStateExists(t *testing.T) {
	seed := map[string]func(home string) string{
		"legacy per-user identity": func(home string) string {
			return filepath.Join(home, ".burrowee", "gateway", "identity", "relay_ed.key")
		},
		"legacy per-user keys": func(home string) string {
			return filepath.Join(home, ".burrowee", "gateway", "keys", "relay_ed.key")
		},
		"legacy per-user store": func(home string) string {
			return filepath.Join(home, ".burrowee", "gateway", "gateway.db")
		},
		"system config identity": func(home string) string {
			return filepath.Join(sysConfigDir(home), "identity", "relay_ed.key")
		},
		"system data store": func(home string) string {
			return filepath.Join(sysDataDir(home), "gateway.db")
		},
	}

	for name, where := range seed {
		t.Run(name, func(t *testing.T) {
			home := t.TempDir()
			stub := stubInitSystem(t)
			staging := t.TempDir()
			seedDummyBins(t, staging)

			p := where(home)
			if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(p, []byte("state"), 0o600); err != nil {
				t.Fatal(err)
			}

			cmd := exec.Command("sh", installShPath(t))
			cmd.Dir = staging
			cmd.Env = installShEnv(home, stub)
			cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("fresh install failed: %v\n%s", err, out)
			}
			if !strings.Contains(string(out), "already set up") {
				t.Errorf("enrolled host was not recognised — setup would be re-prompted:\n%s", out)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// The general case: a migration that fails for ANY reason, not just the
// capability precondition the pre-flight can check up front.
// ---------------------------------------------------------------------------

// TestNoUnitsSurviveAFailedMigration closes the half assert_can_migrate cannot.
// The pre-flight answers one question — can the cli run `migrate` — and a
// migration has many other ways to fail (no passwordless sudo after the daemon
// is stopped, a torn copy, a full disk). A failed migration exits install.sh,
// and the units it had already written stay on disk: launchd bootstraps a
// LaunchDaemon at the next reboot whatever this run reported to its caller.
//
// So render_units moves behind the migration in every mode. Leaving the OLD
// units in place is strictly better than leaving new ones: they point at a tree
// that still holds the host's identity.
func TestNoUnitsSurviveAFailedMigration(t *testing.T) {
	t.Run("units-only", func(t *testing.T) {
		home := t.TempDir()
		stub := stubInitSystem(t)
		bundle := t.TempDir()
		script := stageInstaller(t, bundle)
		logPath := filepath.Join(t.TempDir(), "migration.log")
		seedMigrateCapableCLI(t, home)
		stageMigration(t, bundle, logPath, 1) // the migration FAILS

		out, err := runStaged(t, script, home, home, stub, "BURROWEE_UNITS_ONLY=1")
		if err == nil {
			t.Fatalf("install.sh succeeded despite a failing migration:\n%s", out)
		}
		if migrationLog(t, logPath) == "" {
			t.Fatal("the migration never ran — this test is not exercising the failure")
		}
		assertNoUnitsWritten(t, home)
	})

	t.Run("fresh install", func(t *testing.T) {
		home := t.TempDir()
		stub := stubInitSystem(t)
		bundle := t.TempDir()
		seedDummyBins(t, bundle)
		script := stageInstaller(t, bundle)
		logPath := filepath.Join(t.TempDir(), "migration.log")
		stageMigration(t, bundle, logPath, 1)

		out, err := runStaged(t, script, bundle, home, stub)
		if err == nil {
			t.Fatalf("fresh install succeeded despite a failing migration:\n%s", out)
		}
		if migrationLog(t, logPath) == "" {
			t.Fatal("the migration never ran — this test is not exercising the failure")
		}
		assertNoUnitsWritten(t, home)
	})

	t.Run("update", func(t *testing.T) {
		home := t.TempDir()
		stub := stubInitSystem(t)
		binDir := home + "/.local/bin"
		logPath := filepath.Join(t.TempDir(), "migration.log")

		seedInstalled(t, binDir, withCLI(allBinsContent("v1-content"), cliWithMigrate))
		staged := withCLI(allBinsContent("v1-content"), cliWithMigrate)
		staged["burrowee-gateway"] = "gw-v2-content"
		script, stageDir := stagedUpdateBundle(t, staged, logPath, 1)

		out, err := runStagedArgs(t, script, stageDir, home, stub,
			[]string{"--version", "0.2.0"}, "BURROWEE_UPDATE=1")
		if err == nil {
			t.Fatalf("update succeeded despite a failing migration:\n%s", out)
		}
		if migrationLog(t, logPath) == "" {
			t.Fatal("the migration never ran — this test is not exercising the failure")
		}
		assertNoUnitsWritten(t, home)
	})
}
