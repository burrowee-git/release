// migrations_test.go — the edge installer's use of the SHARED migration ladder
// (inner/_shared/migrations/), staged into every edge kit by tools/payload.sh.
//
// What is asserted here is the WIRING, not the ladder's own logic: that
// install.sh runs the runner unconditionally, that it acts on each of the
// runner's exit codes rather than merely observing them, and that it keeps a
// usable copy of the ladder beside its self-copy. The runner, the sweep library
// and the 0.2.0 rung have their own suite in tools/test-shared-migrations.sh,
// which runs them under dash as well as bash and is itself mutation-checked by
// tools/test-shared-migrations-mutants.sh.
//
// EVERY PATH HERE IS A FIXTURE TREE under t.TempDir().
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// sharedMigrationsDir resolves inner/_shared/migrations relative to this file.
func sharedMigrationsDir(t *testing.T) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "..", "_shared", "migrations"))
	if err != nil {
		t.Fatalf("resolve shared migrations: %v", err)
	}
	if _, err := os.Stat(filepath.Join(p, "run.sh")); err != nil {
		t.Fatalf("shared migrations/run.sh not found under %s: %v", p, err)
	}
	return p
}

// stageMigrations lays a kit's migrations/ into the staging dir exactly as
// tools/payload.sh assembles one: every shared script, plus the component's own
// component.conf and ledger.
//
// The conf and ledger are SYNTHESIZED here rather than read out of the edge
// repo, which this repo cannot see at test time — the same split payload.sh
// has, where the shared half comes from here and the component half comes from
// the component's source worktree. The real edge files are checked in the edge
// repo's own suite; what this asserts is that install.sh drives whatever ladder
// its bundle carries.
func stageMigrations(t *testing.T, staging string) string {
	t.Helper()
	dst := filepath.Join(staging, "migrations")
	if err := os.MkdirAll(dst, 0o755); err != nil {
		t.Fatalf("mkdir migrations: %v", err)
	}
	src := sharedMigrationsDir(t)
	entries, err := os.ReadDir(src)
	if err != nil {
		t.Fatalf("read shared migrations: %v", err)
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sh") {
			continue
		}
		body, err := os.ReadFile(filepath.Join(src, e.Name()))
		if err != nil {
			t.Fatalf("read %s: %v", e.Name(), err)
		}
		if err := os.WriteFile(filepath.Join(dst, e.Name()), body, 0o755); err != nil {
			t.Fatalf("stage %s: %v", e.Name(), err)
		}
	}
	conf := "COMP=edge\nCOMP_HOME_SCHEME=root\nVERSION_FILE=installed-version\n" +
		"STALE_USER_BINS=\"" + strings.Join(edgeBins, " ") + "\"\n"
	if err := os.WriteFile(filepath.Join(dst, "component.conf"), []byte(conf), 0o644); err != nil {
		t.Fatalf("write component.conf: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dst, "ledger"), []byte("0.2.0 stale_user_bins.sh\n"), 0o644); err != nil {
		t.Fatalf("write ledger: %v", err)
	}
	return dst
}

// TestEdgeInstallRunsTheLadder is the headline claim: a plain install walks the
// ladder, and says which input it decided on. Running it unconditionally is the
// point — a caller that decided for itself when the ladder was worth running
// would be a second copy of the gate.
func TestEdgeInstallRunsTheLadder(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	stageMigrations(t, staging)

	_, _, out := runRootInstall(t, home, staging, sandboxLaunchd(home))

	assertContains(t, out, "migrate: ")
	if !strings.Contains(out, "no installed version recorded") &&
		!strings.Contains(out, "installed version ") {
		t.Errorf("the ladder must say which input it decided on; got:\n%s", out)
	}
}

// TestEdgeInstallLadderSweepsAndReceiptsIt — the rung, not the installer step,
// is what does the removing on a host whose anchor is older than 0.2.0, and the
// receipt it leaves is what stops it running again.
//
// $BURROWEE_VERSION is set so the installer writes the version anchor, and the
// anchor is pre-seeded at 0.1.111 so the rung is selected BY THE NUMERIC GATE
// rather than by the --applies probe — the two select the same rung for
// different reasons, and only the gate is exercised by a host that has an
// anchor at all.
func TestEdgeInstallLadderSweepsAndReceiptsIt(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	stageMigrations(t, staging)
	stale := staleDir(home)
	seedStale(t, stale, staleOursSet())

	rootHome := filepath.Join(home, "root-home")
	compHome := filepath.Join(rootHome, ".burrowee", "edge")
	if err := os.MkdirAll(compHome, 0o755); err != nil {
		t.Fatalf("mkdir comp home: %v", err)
	}
	if err := os.WriteFile(filepath.Join(compHome, "installed-version"), []byte("0.1.111\n"), 0o644); err != nil {
		t.Fatalf("seed anchor: %v", err)
	}

	_, _, out := runRootInstall(t, home, staging, sandboxLaunchd(home),
		"BURROWEE_VERSION=edge/v0.2.0.2026.08.17.deadbeef")

	assertContains(t, out,
		"stale_user_bins.sh applies: installed 0.1.111 is older than 0.2.0",
		"migrate: migrations complete.")
	for _, b := range edgeBins {
		assertGone(t, filepath.Join(stale, b), "the ladder rung must remove the stale per-user copy")
	}
	receipt := filepath.Join(compHome, "migration-receipts", "stale_user_bins.sh.done")
	assertPresent(t, receipt, "a rung that ran must leave a receipt")
	body, err := os.ReadFile(receipt)
	if err != nil {
		t.Fatalf("read receipt: %v", err)
	}
	if !strings.Contains(string(body), "comp_home="+compHome) {
		t.Errorf("the receipt must record the tree it was earned for; got %q", body)
	}

	// The anchor advances, so a second install's gate closes the rung.
	anchor, err := os.ReadFile(filepath.Join(compHome, "installed-version"))
	if err != nil {
		t.Fatalf("read anchor: %v", err)
	}
	if !strings.Contains(string(anchor), "0.2.0") {
		t.Errorf("the installer must record the new version after a clean ladder run; got %q", anchor)
	}
}

// TestEdgeInstallKeepsTheLadderBesideItsSelfCopy — install.sh resolves the
// runner and the sweep library relative to its OWN path, so a $COMP_HOME
// holding install.sh without migrations/ is an installer that silently cannot
// migrate and silently stops sweeping. Both look exactly like a clean run.
func TestEdgeInstallKeepsTheLadderBesideItsSelfCopy(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	stageMigrations(t, staging)

	runRootInstall(t, home, staging, sandboxLaunchd(home))

	kept := filepath.Join(home, "root-home", ".burrowee", "edge", "migrations")
	for _, f := range []string{"run.sh", "lib_paths.sh", "lib_stale_user_bins.sh", "stale_user_bins.sh", "component.conf", "ledger"} {
		assertPresent(t, filepath.Join(kept, f), "the self-copied ladder is missing "+f)
	}
}

// TestEdgeInstallStopsWhenTheLadderRefuses — exit 1 from the runner is FATAL.
// Carrying on would write the service units and the version anchor for a
// migration that refused, and the anchor is what closes the gate on that rung
// permanently. The refusal is arranged the way a real one arrives: a ledger row
// whose script is not in the release, which is exactly the mis-assembled zip
// this project has already shipped once.
//
// The units are the observable: the install must stop BEFORE they are written.
func TestEdgeInstallStopsWhenTheLadderRefuses(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	mig := stageMigrations(t, staging)
	if err := os.Remove(filepath.Join(mig, "stale_user_bins.sh")); err != nil {
		t.Fatalf("remove rung: %v", err)
	}

	stub := stubRootEnv(t)
	sysBinDir := filepath.Join(home, "sysbin")
	unitDir := filepath.Join(home, "systemd-system")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		t.Fatalf("mkdir unitDir: %v", err)
	}
	cmd := exec.Command("sh", stagedInstaller(t, staging))
	cmd.Dir = staging
	cmd.Env = []string{
		"HOME=" + home,
		"PATH=" + stub + ":/usr/bin:/bin",
		"STUB_LOG=" + filepath.Join(home, "stub-calls.log"),
		"SYS_BIN_DIR=" + sysBinDir,
		"SYSTEMD_UNIT_DIR=" + unitDir,
		"ROOT_HOME=" + filepath.Join(home, "root-home"),
		sandboxLaunchd(home),
	}
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("install.sh must FAIL when the ladder refuses; it exited 0:\n%s", out)
	}
	assertContains(t, string(out), "THIS RELEASE IS INCOMPLETE",
		"a state migration refused or failed")
	if _, err := os.Stat(filepath.Join(unitDir, "burrowee-edge.service")); err == nil {
		t.Error("a refused ladder must stop the install BEFORE the service unit is written")
	}
}

// TestEdgeInstallWithholdsTheAnchorOnALostReceipt — exit 3 means the rung ran
// and could not be recorded. The receipt and the anchor are the two gates on a
// rung; recording the version with the receipt lost closes the last one on work
// nothing on this host can prove finished, and the rung would then never run
// again. So the install completes and the anchor is deliberately NOT written.
//
// The lost receipt is arranged by putting a FILE where the receipts directory
// has to go, so `mkdir -p` fails while $COMP_HOME itself stays writable — the
// receipt is lost and nothing else is.
func TestEdgeInstallWithholdsTheAnchorOnALostReceipt(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	stageMigrations(t, staging)
	seedStale(t, staleDir(home), staleOursSet())

	compHome := filepath.Join(home, "root-home", ".burrowee", "edge")
	if err := os.MkdirAll(compHome, 0o755); err != nil {
		t.Fatalf("mkdir comp home: %v", err)
	}
	if err := os.WriteFile(filepath.Join(compHome, "migration-receipts"), []byte("in the way\n"), 0o644); err != nil {
		t.Fatalf("block receipts dir: %v", err)
	}

	_, _, out := runRootInstall(t, home, staging, sandboxLaunchd(home),
		"BURROWEE_VERSION=edge/v0.2.0.2026.08.17.deadbeef")

	assertContains(t, out,
		"is NOT recorded",
		"the installed version is deliberately NOT recorded")
	if _, err := os.Stat(filepath.Join(compHome, "installed-version")); err == nil {
		t.Error("the version anchor must be withheld when a rung ran without its receipt")
	}
	// The rung still RAN — exit 3 is exit 2 plus a lost receipt, not a refusal.
	assertGone(t, filepath.Join(staleDir(home), "burrowee-edge"),
		"exit 3 still means the rung ran")
}

// TestEdgeInstallWithoutAMigrationsDirStillInstalls — a bundle carrying no
// migrations/ at all is an OLD bundle, not a broken one: the $COMP_HOME
// self-copy from an install predating the directory is exactly that, and
// BURROWEE_UNITS_ONLY runs it. It must install, and it must say the sweep did
// not happen rather than reporting a sweep that found nothing.
func TestEdgeInstallWithoutAMigrationsDirStillInstalls(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	stale := staleDir(home)
	seedStale(t, stale, staleOursSet())

	_, _, out := runRootInstall(t, home, staging, sandboxLaunchd(home))

	assertContains(t, out, "edge system install complete.")
	assertNotContains(t, out, "removed stale per-user binary",
		"a bundle with no library must not claim to have swept anything")
	assertPresent(t, filepath.Join(stale, "burrowee-edge"),
		"with no library loaded nothing may be removed")
}

// TestEdgeInstallReportsAMismatchedBinaryList — $BINS is what the installer
// PLACES and component.conf's $STALE_USER_BINS is what the sweep removes. A
// name in one and not the other is a binary that is installed and never swept
// (it keeps shadowing $BIN_DIR on PATH) or swept and never installed, and
// neither is visible without saying so: the sweep's normal output on a
// converged host is nothing at all.
func TestEdgeInstallReportsAMismatchedBinaryList(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	mig := stageMigrations(t, staging)
	conf := "COMP=edge\nCOMP_HOME_SCHEME=root\nVERSION_FILE=installed-version\n" +
		"STALE_USER_BINS=\"burrowee burrowee-edge\"\n"
	if err := os.WriteFile(filepath.Join(mig, "component.conf"), []byte(conf), 0o644); err != nil {
		t.Fatalf("write component.conf: %v", err)
	}

	_, _, out := runRootInstall(t, home, staging, sandboxLaunchd(home))

	assertContains(t, out, "the two lists disagree")
}

// assertNotContains is assertContains' opposite, with the same output dump — a
// negative claim that prints nothing on failure is a claim nobody can diagnose.
func assertNotContains(t *testing.T, s, unwanted, why string) {
	t.Helper()
	if strings.Contains(s, unwanted) {
		t.Errorf("%s: output unexpectedly contains %q\ngot:\n%s", why, unwanted, s)
	}
}

// TestEdgeInstallerSweepsEvenWhenTheLadderDoesNot is the reason the sweep stays
// in install.sh as well as being a ladder rung, asserted rather than
// asserted-in-a-comment.
//
// The anchor already reads 0.2.0, so the numeric gate closes the rung and the
// ladder applies nothing — the state of any host that has already taken this
// release. Stale per-user copies are nevertheless present, and the installer's
// OWN sweep is the only thing left that can remove them. A fresh install must
// not depend on the ladder being coherent, and this is what says so.
func TestEdgeInstallerSweepsEvenWhenTheLadderDoesNot(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedEdgeBins(t, staging)
	stageMigrations(t, staging)
	stale := staleDir(home)
	seedStale(t, stale, staleOursSet())

	compHome := filepath.Join(home, "root-home", ".burrowee", "edge")
	if err := os.MkdirAll(compHome, 0o755); err != nil {
		t.Fatalf("mkdir comp home: %v", err)
	}
	if err := os.WriteFile(filepath.Join(compHome, "installed-version"),
		[]byte("0.2.0.2026.08.17.4e43c2ed\n"), 0o644); err != nil {
		t.Fatalf("seed anchor: %v", err)
	}

	_, _, out := runRootInstall(t, home, staging, sandboxLaunchd(home))

	if !strings.Contains(out, "migrate: nothing applied") {
		t.Fatalf("precondition: the 0.2.0 anchor must close the gate; got:\n%s", out)
	}
	for _, b := range edgeBins {
		assertGone(t, filepath.Join(stale, b),
			"install.sh's own sweep did not run — the stale copy still shadows the system bin dir")
	}
}
