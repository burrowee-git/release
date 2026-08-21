// migrations_test.go — the cli installer's use of the SHARED migration ladder
// (inner/_shared/migrations/), staged into every cli kit by tools/payload.sh.
//
// What is asserted here is the WIRING plus the one decision that is the cli's
// own: the shared `burrowee` dispatcher is not the cli's to remove while
// another burrowee component is still installed in the same per-user directory.
// The runner, the sweep library and the 0.2.0 rung have their own suite in
// tools/test-shared-migrations.sh, run under dash as well as bash and
// mutation-checked by tools/test-shared-migrations-mutants.sh.
//
// EVERY PATH HERE IS A FIXTURE TREE under t.TempDir(). Nothing may resolve to a
// real $HOME/.local/bin, /etc/systemd/system or /Library/LaunchDaemons — the
// machines this suite runs on carry live burrowee installs in exactly those
// places, and the thing under test deletes files.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// stampedBinary stands in for a real burrowee binary: NUL bytes and an ELF
// header around the module path the Go toolchain stamps into every
// github.com/burrowee-git/* executable's build-info blob.
//
// The NULs are load-bearing. The sweep decides ownership with `grep -qF` over
// the file's bytes, and a plain-text fixture would prove the predicate matches
// a string, which was never in doubt. tools/test-shared-migrations.sh goes
// further and compiles REAL Go binaries for both sides of that decision; this
// file only needs the two to be distinguishable.
func stampedBinary(name string) []byte {
	return []byte("\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00" +
		"go1.26.5\x00path\tgithub.com/burrowee-git/cli/cmd/" + name + "\x00\x00\n")
}

// foreignBinary is a file that is NOT ours: an operator's own script of the
// kind that shares a name or a prefix with what this component installs.
const foreignBinary = "#!/bin/sh\n# my own wrapper — nothing to do with the vendor\nexec /opt/local/thing \"$@\"\n"

// stageCliMigrations lays a kit's migrations/ into staging exactly as
// tools/payload.sh assembles one: every shared script, plus the component's own
// component.conf and ledger.
//
// The conf and ledger are SYNTHESIZED rather than read out of the cli repo,
// which this repo cannot see at test time — the same split payload.sh has. The
// real cli files are checked in the cli repo's own suite; what this asserts is
// that install.sh drives whatever ladder its bundle carries.
func stageCliMigrations(t *testing.T, staging string) string {
	t.Helper()
	src, err := filepath.Abs(filepath.Join("..", "..", "_shared", "migrations"))
	if err != nil {
		t.Fatalf("resolve shared migrations: %v", err)
	}
	if _, err := os.Stat(filepath.Join(src, "run.sh")); err != nil {
		t.Fatalf("shared migrations/run.sh not found under %s: %v", src, err)
	}
	dst := filepath.Join(staging, "migrations")
	if err := os.MkdirAll(dst, 0o755); err != nil {
		t.Fatalf("mkdir migrations: %v", err)
	}
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
	conf := "COMP=cli\nCOMP_HOME_SCHEME=user\nVERSION_FILE=.installed-version\n" +
		"STALE_USER_BINS=\"" + strings.Join(cliBins, " ") + "\"\n"
	if err := os.WriteFile(filepath.Join(dst, "component.conf"), []byte(conf), 0o644); err != nil {
		t.Fatalf("write component.conf: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dst, "ledger"), []byte("0.2.0 stale_user_bins.sh\n"), 0o644); err != nil {
		t.Fatalf("write ledger: %v", err)
	}
	return dst
}

// stagedCliInstaller copies install.sh INTO dir and returns the copy's path.
// install.sh resolves migrations/ relative to its OWN path, which in production
// is the unzipped release dir; running the repo's copy would resolve it next to
// inner/cli/ instead, where there is none, and every assertion below would be
// measuring a bundle shape no host receives.
func stagedCliInstaller(t *testing.T, dir string) string {
	t.Helper()
	body, err := os.ReadFile(installShPath(t))
	if err != nil {
		t.Fatalf("read install.sh: %v", err)
	}
	p := filepath.Join(dir, "install.sh")
	if err := os.WriteFile(p, body, 0o755); err != nil {
		t.Fatalf("stage install.sh: %v", err)
	}
	return p
}

// sandboxedRun runs the STAGED installer with every system scan redirected into
// the sandbox, and hands back the output and the process error rather than
// failing on a non-zero exit — the refusal cases need to inspect both.
//
// prefix is the install destination. It is a PARAMETER because the cli's
// default destination IS the directory the sweep would consider, so a suite
// that only ever ran the default could never exercise the sweep at all.
//
// LAUNCHD_DIR / SYSTEMD_DIR are not optional: the library's defaults are the
// REAL /Library/LaunchDaemons and /etc/systemd/system, which exist on the
// machines this runs on and are not this suite's to read.
func sandboxedRun(t *testing.T, home, staging, prefix string, extraEnv ...string) (string, error) {
	t.Helper()
	cmd := exec.Command("sh", stagedCliInstaller(t, staging))
	cmd.Dir = staging
	cmd.Env = append([]string{
		"HOME=" + home,
		"PREFIX=" + prefix,
		"PATH=/usr/bin:/bin",
		"LAUNCHD_DIR=" + filepath.Join(home, "no-launchd"),
		"SYSTEMD_DIR=" + filepath.Join(home, "no-systemd"),
		"BURROWEE_LEGACY_HOME_PARENTS=" + filepath.Join(home, "nowhere"),
	}, extraEnv...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func seedPerUserBins(t *testing.T, dir string, stamped []string, foreign []string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", dir, err)
	}
	for _, n := range stamped {
		if err := os.WriteFile(filepath.Join(dir, n), stampedBinary(n), 0o755); err != nil {
			t.Fatalf("seed %s: %v", n, err)
		}
	}
	for _, n := range foreign {
		if err := os.WriteFile(filepath.Join(dir, n), []byte(foreignBinary), 0o755); err != nil {
			t.Fatalf("seed %s: %v", n, err)
		}
	}
}

// TestCliInstallRunsTheLadder — the ladder is walked unconditionally, and says
// which input it decided on. On a DEFAULT cli install it must then apply
// nothing: the directory the sweep would consider is the install destination.
func TestCliInstallRunsTheLadder(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	stageCliMigrations(t, staging)
	perUser := filepath.Join(home, ".local", "bin")
	seedPerUserBins(t, perUser, cliBins, nil)

	out, err := sandboxedRun(t, home, staging, filepath.Join(home, ".local"))
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	if !strings.Contains(out, "migrate: ") {
		t.Errorf("the ladder must run on every install; got:\n%s", out)
	}
	if !strings.Contains(out, "migrate: nothing applied") {
		t.Errorf("a default cli install has nothing to sweep — the sweep dir IS $BIN_DIR; got:\n%s", out)
	}
	for _, b := range cliBins {
		if _, err := os.Stat(filepath.Join(perUser, b)); err != nil {
			t.Errorf("the cli's own live install was swept: %s is gone", b)
		}
	}
}

// TestCliLadderSweepsWhenTheDestinationIsElsewhere — the case the cli's rung
// exists for. With $BIN_DIR somewhere other than ~/.local/bin, the per-user
// copies really are stale and really do shadow it on PATH, and the rung removes
// them.
//
// The version anchor is pre-seeded at 0.1.111 so the rung is selected BY THE
// NUMERIC GATE rather than by the --applies probe: the two select the same rung
// for different reasons, and only the gate is exercised by a host that has an
// anchor at all.
func TestCliLadderSweepsWhenTheDestinationIsElsewhere(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	stageCliMigrations(t, staging)
	perUser := filepath.Join(home, ".local", "bin")
	seedPerUserBins(t, perUser, cliBins, nil)

	compHome := filepath.Join(home, ".burrowee", "cli")
	if err := os.MkdirAll(compHome, 0o755); err != nil {
		t.Fatalf("mkdir comp home: %v", err)
	}
	if err := os.WriteFile(filepath.Join(compHome, ".installed-version"), []byte("0.1.111\n"), 0o644); err != nil {
		t.Fatalf("seed anchor: %v", err)
	}

	out, err := sandboxedRun(t, home, staging, filepath.Join(home, "opt"),
		"BURROWEE_VERSION=cli/v0.2.0.2026.08.17.deadbeef")
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	if !strings.Contains(out, "stale_user_bins.sh applies: installed 0.1.111 is older than 0.2.0") {
		t.Errorf("the numeric gate must select the rung; got:\n%s", out)
	}
	for _, b := range cliBins {
		if _, err := os.Stat(filepath.Join(perUser, b)); err == nil {
			t.Errorf("%s still shadows the install destination on PATH", b)
		}
		if _, err := os.Stat(filepath.Join(home, "opt", "bin", b)); err != nil {
			t.Errorf("the sweep took the binary this run installed: %s", b)
		}
	}
	// The receipt is PER ITEM — keyed by the ledger row's script AND target —
	// so a file re-listed at a newer target can never be satisfied by the
	// receipt an older row earned.
	receipt := filepath.Join(compHome, "migration-receipts", "stale_user_bins.sh@0.2.0.done")
	if body, err := os.ReadFile(receipt); err != nil {
		t.Errorf("no receipt at %s: %v", receipt, err)
	} else if !strings.Contains(string(body), "comp_home="+compHome) {
		t.Errorf("the receipt must record the tree it was earned for; got %q", body)
	} else if !strings.Contains(string(body), "target=0.2.0") {
		t.Errorf("the receipt must record the ledger target it was earned for; got %q", body)
	}
	anchor, err := os.ReadFile(filepath.Join(compHome, ".installed-version"))
	if err != nil {
		t.Fatalf("read anchor: %v", err)
	}
	if !strings.Contains(string(anchor), "0.2.0") {
		t.Errorf("the installer must record the new version after a clean ladder run; got %q", anchor)
	}
}

// TestCliLadderRemovesTheSharedDispatcherOnceARootOneExists IS THE CLI'S RULE,
// and the operator reversed it: "burrowee dispatcher should be removed and only
// root dispatcher exists."
//
// The previous rule removed the per-user `burrowee` only when, after the cli's
// own names had gone, no remaining burrowee-* file in that directory carried the
// github.com/burrowee-git/ build stamp — so a co-installed burrowee-gateway
// pinned it. On a real host that is what kept a stale dispatcher alive through
// an upgrade, and ~/.local/bin precedes the system bin dir on a normal PATH, so
// every later `burrowee …` ran old code.
//
// The rule is now the root-twin predicate and nothing else. It strands no
// component: burrowee's main.go pins only gateway, edge and register to
// /usr/local/bin and resolves the rest through PATH and then {/usr/local/bin,
// /opt/homebrew/bin, ~/.local/bin}, so the per-user burrowee-gateway below is
// still reachable — and is still not the cli's to remove.
func TestCliLadderRemovesTheSharedDispatcherOnceARootOneExists(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	stageCliMigrations(t, staging)
	perUser := filepath.Join(home, ".local", "bin")
	seedPerUserBins(t, perUser, append(append([]string{}, cliBins...), "burrowee-gateway"), nil)

	out, err := sandboxedRun(t, home, staging, filepath.Join(home, "opt"))
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	if _, err := os.Stat(filepath.Join(perUser, "burrowee")); err == nil {
		t.Errorf("this install placed a root dispatcher, so the per-user one must go:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(perUser, "burrowee-gateway")); err != nil {
		t.Errorf("another component's binary is not the cli's to remove, and it has no root twin")
	}
	if _, err := os.Stat(filepath.Join(perUser, "burrowee-cli")); err == nil {
		t.Errorf("the cli's own names must still go")
	}
}

// TestCliLadderRemovesTheDispatcherWhenNothingElseIsOurs — the other half of
// the same rule, and the half that makes the first one a rule rather than a
// blanket refusal. With no other burrowee component left in that directory the
// shadowing dispatcher goes; an operator's OWN burrowee-* file is not evidence
// a component is installed and must not pin it forever.
func TestCliLadderRemovesTheDispatcherWhenNothingElseIsOurs(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	stageCliMigrations(t, staging)
	perUser := filepath.Join(home, ".local", "bin")
	seedPerUserBins(t, perUser, cliBins, []string{"burrowee-notes"})

	out, err := sandboxedRun(t, home, staging, filepath.Join(home, "opt"))
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	if _, err := os.Stat(filepath.Join(perUser, "burrowee")); err == nil {
		t.Errorf("with nothing else of ours left, the shadowing dispatcher must go:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(perUser, "burrowee-notes")); err != nil {
		t.Errorf("an operator's own burrowee-* file must be left alone")
	}
}

// TestCliInstallStopsWhenTheLadderRefuses — exit 1 from the runner is FATAL.
// Arranged the way a real refusal arrives: a ledger row whose script is not in
// the release, which is exactly the mis-assembled zip this project has already
// shipped once. The version anchor is the observable — writing it would close
// the gate on that rung permanently.
func TestCliInstallStopsWhenTheLadderRefuses(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	mig := stageCliMigrations(t, staging)
	if err := os.Remove(filepath.Join(mig, "stale_user_bins.sh")); err != nil {
		t.Fatalf("remove rung: %v", err)
	}

	out, err := sandboxedRun(t, home, staging, filepath.Join(home, "opt"),
		"BURROWEE_VERSION=cli/v0.2.0.2026.08.17.deadbeef")
	if err == nil {
		t.Fatalf("install.sh must FAIL when the ladder refuses; it exited 0:\n%s", out)
	}
	if !strings.Contains(out, "THIS RELEASE IS INCOMPLETE") {
		t.Errorf("the refusal must name the cause; got:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(home, ".burrowee", "cli", ".installed-version")); err == nil {
		t.Error("a refused ladder must not leave a version anchor behind")
	}
}

// TestCliInstallWithoutAMigrationsDirStillInstalls — a bundle carrying no
// migrations/ is an OLD bundle, not a broken one, and it must install and say
// nothing about a sweep it did not perform.
func TestCliInstallWithoutAMigrationsDirStillInstalls(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	perUser := filepath.Join(home, ".local", "bin")
	seedPerUserBins(t, perUser, cliBins, nil)

	out, err := sandboxedRun(t, home, staging, filepath.Join(home, "opt"))
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	if strings.Contains(out, "removed stale per-user binary") {
		t.Errorf("a bundle with no library must not claim to have swept anything:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(perUser, "burrowee-cli")); err != nil {
		t.Errorf("with no library loaded nothing may be removed")
	}
}

// TestCliInstallKeepsTheLadderBesideItsSelfCopy — install.sh resolves the runner
// and the sweep library relative to its OWN path, so a $COMP_HOME holding
// install.sh without migrations/ is an installer that silently cannot migrate
// and silently stops sweeping.
func TestCliInstallKeepsTheLadderBesideItsSelfCopy(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	stageCliMigrations(t, staging)

	out, err := sandboxedRun(t, home, staging, filepath.Join(home, ".local"))
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	kept := filepath.Join(home, ".burrowee", "cli", "migrations")
	for _, f := range []string{"run.sh", "lib_paths.sh", "lib_stale_user_bins.sh", "stale_user_bins.sh", "component.conf", "ledger"} {
		if _, err := os.Stat(filepath.Join(kept, f)); err != nil {
			t.Errorf("the self-copied ladder is missing %s: %v\n%s", f, err, out)
		}
	}
}

// TestCliFreshInstallStillPromptsWithALadder — the ordering trap. The first-run
// setup check reads "$COMP_HOME is non-empty" as "this cli is already set up",
// so a ladder that created $COMP_HOME or wrote the version anchor before that
// check would make every FRESH install silently skip the setup prompt. There is
// no tty here, so the observable is the non-interactive branch's own line.
func TestCliFreshInstallStillPromptsWithALadder(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	stageCliMigrations(t, staging)

	out, err := sandboxedRun(t, home, staging, filepath.Join(home, ".local"),
		"BURROWEE_VERSION=cli/v0.2.0.2026.08.17.deadbeef")
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	if strings.Contains(out, "already set up") {
		t.Errorf("a FRESH install must not look already-set-up because the ladder ran:\n%s", out)
	}
	if !strings.Contains(out, "next: burrowee cli bootstrap") {
		t.Errorf("the fresh-install next step must still be printed:\n%s", out)
	}
}

// TestCliInstallerSweepsEvenWhenTheLadderDoesNot is the reason
// remove_stale_user_bins stays in install.sh as well as being a ladder rung,
// asserted rather than asserted-in-a-comment.
//
// The anchor already reads 0.2.0, so the numeric gate closes the rung and the
// ladder applies nothing — the state of any host that has already taken this
// release. Stale per-user copies are nevertheless present, and the installer's
// OWN sweep is the only thing left that can remove them. Delete that call and
// this test is the one that reddens; without it, every cli assertion about
// sweeping is satisfied by the rung and the fresh-install path is untested.
func TestCliInstallerSweepsEvenWhenTheLadderDoesNot(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	stageCliMigrations(t, staging)
	perUser := filepath.Join(home, ".local", "bin")
	seedPerUserBins(t, perUser, cliBins, nil)

	compHome := filepath.Join(home, ".burrowee", "cli")
	if err := os.MkdirAll(compHome, 0o755); err != nil {
		t.Fatalf("mkdir comp home: %v", err)
	}
	if err := os.WriteFile(filepath.Join(compHome, ".installed-version"),
		[]byte("0.2.0.2026.08.17.4e43c2ed\n"), 0o644); err != nil {
		t.Fatalf("seed anchor: %v", err)
	}

	out, err := sandboxedRun(t, home, staging, filepath.Join(home, "opt"))
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	// The ladder really did decline — otherwise this test would be measuring
	// the rung again under a different name.
	if !strings.Contains(out, "migrate: nothing applied") {
		t.Fatalf("precondition: the 0.2.0 anchor must close the gate; got:\n%s", out)
	}
	for _, b := range cliBins {
		if b == "burrowee" {
			continue // the dispatcher has its own rule, tested above
		}
		if _, err := os.Stat(filepath.Join(perUser, b)); err == nil {
			t.Errorf("install.sh's own sweep did not run: %s still shadows the destination", b)
		}
	}
	if !strings.Contains(out, "removed stale per-user binary") {
		t.Errorf("the installer's own sweep must report what it removed; got:\n%s", out)
	}
}
