// user_tree_test.go — the cli installer's FIRST act: ~/.burrowee/cli and
// ~/.burrowee/cli/sockets, created at 0700 as the invoking account, or a
// refusal that names what is wrong and installs nothing.
//
// ~/.burrowee is the user's own tree and this installer is the only thing that
// creates it (operator ruling 2026-09-05). What it replaced was three
// `mkdir -p "$COMP_HOME" 2>/dev/null || true` scattered through the second half
// of the script: on a host whose ~/.burrowee an older root-run gateway
// installer had taken, every one of them failed silently and the install
// reported success — the first thing to say anything was `burrowee bootstrap`,
// long after the operator had been told the cli was installed.
//
// HOW THE REFUSAL IS REACHED WITHOUT ROOT. No unprivileged suite can create a
// directory owned by somebody else, so the tests below move the OTHER side of
// the comparison instead: an `id` on PATH that reports a different uid, which
// is the technique inner/gateway/install_test's fakeRootUID already uses for
// the same reason. That is also why install.sh compares `stat`'s owner uid
// against `id -u` rather than asking the shell's `[ -O ]`, which reads the euid
// out of the process where no test can reach it.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// runTreeInstall runs the STAGED installer against a sandbox HOME with stubDir
// (when given) ahead of the real tools on PATH, and hands back both the output
// and the process error — the refusal cases need to inspect both.
//
// It does not reuse sandboxedRun (migrations_test.go) because that one pins
// PATH itself, and a second PATH= appended to the environment is resolved
// differently by different libcs.
func runTreeInstall(t *testing.T, home, staging, stubDir string, extraEnv ...string) (string, error) {
	t.Helper()
	path := "/usr/bin:/bin"
	if stubDir != "" {
		path = stubDir + ":" + path
	}
	cmd := exec.Command("sh", stagedCliInstaller(t, staging))
	cmd.Dir = staging
	cmd.Env = append([]string{
		"HOME=" + home,
		"PREFIX=" + filepath.Join(home, ".local"),
		"PATH=" + path,
	}, extraEnv...)
	// Setsid for the same reason tty_probe_test.go needs it: with the suite's
	// own controlling terminal inherited, the installer takes the interactive
	// setup branch and blocks on a prompt nobody answers.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// stubUID drops an `id` stub that answers a bare `id -u` with uid and passes
// every other invocation — `id -un <uid>`, which the messages use to name an
// account — through to the real one, so the refusal it triggers is rendered
// from real passwd data and not from the stub's imagination.
func stubUID(t *testing.T, uid string) string {
	t.Helper()
	dir := t.TempDir()
	body := "#!/bin/sh\n" +
		"if [ $# -eq 1 ] && [ \"$1\" = \"-u\" ]; then echo " + uid + "; exit 0; fi\n" +
		"exec /usr/bin/id \"$@\"\n"
	if err := os.WriteFile(filepath.Join(dir, "id"), []byte(body), 0o755); err != nil {
		t.Fatalf("write id stub: %v", err)
	}
	return dir
}

// otherUID is a uid this suite is certain it is not running as, for the
// ordinary "somebody else owns your tree" refusal. 0 has its own test below,
// because at uid 0 the remedy is different.
const otherUID = "4242"

// noBinariesPlaced asserts the install placed nothing — the half of "refuses
// loudly" that a message assertion cannot see. The check must run BEFORE any
// binary is copied, or a refusal leaves a half-installed host.
func noBinariesPlaced(t *testing.T, home, out string) {
	t.Helper()
	binDir := filepath.Join(home, ".local", "bin")
	for _, b := range cliBins {
		if _, err := os.Stat(filepath.Join(binDir, b)); err == nil {
			t.Errorf("the refusal came AFTER %s was placed in %s — a refused install must leave nothing:\n%s", b, binDir, out)
		}
	}
}

// TestCliFreshInstallCreatesTheUserTreeAt0700 — the tree is the install's own
// precondition, not a side effect of the ladder, the version anchor and the
// self-copy each creating it in passing.
//
// 0700 is asserted exactly. Under the release umask (022) a plain `mkdir -p`
// yields 0755, so a mode assertion is the only thing that can tell the two
// apart, and the sockets/ directory holds the daemon's listening socket.
func TestCliFreshInstallCreatesTheUserTreeAt0700(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)

	out, err := runTreeInstall(t, home, staging, "")
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	compHome := filepath.Join(home, ".burrowee", "cli")
	for _, d := range []string{compHome, filepath.Join(compHome, "sockets")} {
		fi, err := os.Stat(d)
		if err != nil {
			t.Fatalf("the installer did not create %s: %v\n%s", d, err, out)
		}
		if !fi.IsDir() {
			t.Errorf("%s is not a directory", d)
		}
		if perm := fi.Mode().Perm(); perm != 0o700 {
			t.Errorf("%s is mode %04o, want 0700", d, perm)
		}
	}
	for _, b := range cliBins {
		if _, err := os.Stat(filepath.Join(home, ".local", "bin", b)); err != nil {
			t.Errorf("binary not installed: %s: %v", b, err)
		}
	}
}

// TestCliInstallRefusesATreeOwnedBySomebodyElse — the host this feature exists
// for: an older root-run gateway installer took ~/.burrowee, so the cli cannot
// create its own directory under it. The old installer said nothing and exited
// 0; this one names the path, both accounts and the by-hand remedy, and places
// nothing.
//
// No chown and no elevation, deliberately: the tree is the user's, and one a
// root-run installer already took is the operator's to hand back (operator
// ruling 2026-09-05, the same rule `burrowee doctor --fix` follows).
func TestCliInstallRefusesATreeOwnedBySomebodyElse(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: the tree this test creates would be root-owned, so the stub uid would own it too")
	}
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	treeRoot := filepath.Join(home, ".burrowee")
	if err := os.Mkdir(treeRoot, 0o755); err != nil {
		t.Fatalf("seed tree root: %v", err)
	}

	out, err := runTreeInstall(t, home, staging, stubUID(t, otherUID))
	if err == nil {
		t.Fatalf("install.sh must FAIL on a tree it does not own; it exited 0:\n%s", out)
	}

	if !strings.Contains(out, treeRoot) {
		t.Errorf("the refusal must name the directory; got:\n%s", out)
	}
	if !strings.Contains(out, "chown -R") {
		t.Errorf("the refusal must name the by-hand remedy; got:\n%s", out)
	}
	if !strings.Contains(out, "uid "+otherUID) {
		t.Errorf("the refusal must name the account this installer runs as; got:\n%s", out)
	}
	noBinariesPlaced(t, home, out)
	if _, err := os.Stat(filepath.Join(home, ".burrowee", "cli")); err == nil {
		t.Errorf("nothing may be created under a tree the installer does not own:\n%s", out)
	}
}

// TestCliInstallRefusesToTakeAUsersTreeAsRoot is the SAME check read from the
// other side, and it needs its own message: `sudo sh install.sh` against a
// human's ~/.burrowee must not advise `chown -R 0` on their own directory —
// the invocation is what has to change. It is the installer half of the guard
// `burrowee doctor --fix` grew for the same reason.
func TestCliInstallRefusesToTakeAUsersTreeAsRoot(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: the tree this test creates would be root-owned, so the refusal is unreachable")
	}
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	if err := os.Mkdir(filepath.Join(home, ".burrowee"), 0o755); err != nil {
		t.Fatalf("seed tree root: %v", err)
	}

	out, err := runTreeInstall(t, home, staging, stubUID(t, "0"))
	if err == nil {
		t.Fatalf("install.sh must FAIL when root meets a user's tree; it exited 0:\n%s", out)
	}
	if !strings.Contains(out, "WITHOUT sudo") {
		t.Errorf("the refusal must tell root to re-run unprivileged; got:\n%s", out)
	}
	if strings.Contains(out, "chown -R 0") {
		t.Errorf("a human's own tree must never be advised away to root; got:\n%s", out)
	}
	noBinariesPlaced(t, home, out)
}

// TestCliInstallLeavesAnExistingTreeAlone — the tree is created, never
// converged. An install that re-moded or emptied a tree it found would be a
// second way to lose state, and the mode is the operator's once the directory
// exists.
func TestCliInstallLeavesAnExistingTreeAlone(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	compHome := filepath.Join(home, ".burrowee", "cli")
	socks := filepath.Join(compHome, "sockets")
	if err := os.MkdirAll(socks, 0o700); err != nil {
		t.Fatalf("seed tree: %v", err)
	}
	if err := os.Chmod(compHome, 0o750); err != nil {
		t.Fatalf("chmod comp home: %v", err)
	}
	identity := filepath.Join(compHome, "identity")
	if err := os.WriteFile(identity, []byte("enrolled\n"), 0o600); err != nil {
		t.Fatalf("seed identity: %v", err)
	}

	out, err := runTreeInstall(t, home, staging, "")
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}

	body, err := os.ReadFile(identity)
	if err != nil || string(body) != "enrolled\n" {
		t.Errorf("existing state was disturbed: %q %v", body, err)
	}
	fi, err := os.Stat(compHome)
	if err != nil {
		t.Fatalf("stat comp home: %v", err)
	}
	if perm := fi.Mode().Perm(); perm != 0o750 {
		t.Errorf("the installer re-moded an existing tree: %04o, want the 0750 it found", perm)
	}
	if !strings.Contains(out, "already set up") {
		t.Errorf("a tree carrying real state is already set up; got:\n%s", out)
	}
}

// TestCliEmptyTreeStillLooksLikeAFreshInstall is the ordering trap this
// feature walks straight into, and the reason the first-run check no longer
// reads "$COMP_HOME is non-empty".
//
// The setup check treats a non-empty $COMP_HOME as "this cli is already set
// up". Creating the tree first — which is the whole point of the feature —
// makes $COMP_HOME hold sockets/ before that check runs, so an unchanged check
// would report every FRESH install as already-configured and silently skip the
// setup prompt. Seeded here as the state a `doctor --fix` leaves behind: the
// tree, and nothing in it.
func TestCliEmptyTreeStillLooksLikeAFreshInstall(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	if err := os.MkdirAll(filepath.Join(home, ".burrowee", "cli", "sockets"), 0o700); err != nil {
		t.Fatalf("seed tree: %v", err)
	}

	out, err := runTreeInstall(t, home, staging, "")
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	if strings.Contains(out, "already set up") {
		t.Errorf("an empty tree is not state — this install is fresh:\n%s", out)
	}
	if !strings.Contains(out, "next: burrowee cli bootstrap") {
		t.Errorf("the fresh-install next step must still be printed:\n%s", out)
	}
}

// TestCliInstallDoesNotRefuseWhenItCannotLook — the other side of the
// ownership check, and the one a refusal-only suite would miss.
//
// `stat` here answers neither dialect, so the uid comparison has nothing to
// compare and the shell's own `[ -O ]` has to carry the answer. An installer
// that treated "I could not look" as "not yours" would refuse on a host whose
// tree is perfectly fine and leave the operator a remedy for a defect they do
// not have — a false refusal removes the only path they had left.
func TestCliInstallDoesNotRefuseWhenItCannotLook(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	stubs := t.TempDir()
	if err := os.WriteFile(filepath.Join(stubs, "stat"), []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatalf("write stat stub: %v", err)
	}

	out, err := runTreeInstall(t, home, staging, stubs)
	if err != nil {
		t.Fatalf("a host whose stat cannot answer must still install: %v\n%s", err, out)
	}
	if _, err := os.Stat(filepath.Join(home, ".burrowee", "cli", "sockets")); err != nil {
		t.Errorf("the tree was not created: %v\n%s", err, out)
	}
}

// TestCliUninstallDoesNotCreateTheTree — the tree belongs to an install. The
// creation sits after the units-only and uninstall branches so that removing
// the cli, or a units-only reinstall, never leaves a directory behind on a
// host that has none.
func TestCliUninstallDoesNotCreateTheTree(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)

	out, err := runTreeInstall(t, home, staging, "", "BURROWEE_UNINSTALL=1")
	if err != nil {
		t.Fatalf("uninstall failed: %v\n%s", err, out)
	}
	if _, err := os.Stat(filepath.Join(home, ".burrowee")); err == nil {
		t.Errorf("an uninstall created the tree it exists to remove state from:\n%s", out)
	}
}
