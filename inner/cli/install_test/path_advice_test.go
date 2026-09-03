// path_advice_test.go — the "Next steps" block, for the two UNPRIVILEGED
// installers.
//
// The cli and the agent keep their per-user ${PREFIX:-$HOME/.local}/bin
// destination; nothing about where they install changes here. What changes is
// how they say the directory is not on PATH. They used to print one
// conditional line — "note: <dir> is not on PATH — add: export PATH=…" — with
// no shell detection, no profile file named, and suppressed whenever the
// directory happened to be on the PATH of the shell that ran the installer.
//
// They now print the same block every system installer does, from the same
// shared renderer, and the difference between them is only how the subject is
// learned. A root installer under `curl … | sudo sh` has to resolve $SUDO_USER
// through the passwd database, because its own $SHELL and $HOME describe root.
// These two run as the operator, so $SHELL and $HOME are exact and no lookup
// happens at all — which is the case asserted here, since the passwd path is
// already covered against the library in
// inner/edge/install_test/path_advice_test.go.
//
// THE AGENT VENDORS THE RENDERER rather than sourcing it, and that is a
// property of the kit, not a preference: tools/payload.sh stages migrations/
// only for the components takes_shared_ladder names (edge, cli, relay), so an
// agent kit carries no migrations/ directory at all and has nothing to source.
// TestAgentInstallPrintsThePathAdvice below drives its copy, so the two cannot
// drift silently.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// agentInstallShPath resolves inner/agent/install.sh relative to this file.
// The agent has no install_test package of its own — it lays no unit, runs no
// ladder, and this one claim is all there is to make about it.
func agentInstallShPath(t *testing.T) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "..", "agent", "install.sh"))
	if err != nil {
		t.Fatalf("resolve agent install.sh: %v", err)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("agent install.sh not found at %s: %v", p, err)
	}
	return p
}

// seedAgentBins lays the two binaries the agent installer copies from cwd.
func seedAgentBins(t *testing.T, dir string) {
	t.Helper()
	for _, b := range []string{"burrowee", "burrowee-agent"} {
		body := "#!/bin/sh\n# github.com/burrowee-git/agent/cmd/" + b + "\necho " + b + "\n"
		if err := os.WriteFile(filepath.Join(dir, b), []byte(body), 0o755); err != nil {
			t.Fatalf("seed bin %s: %v", b, err)
		}
	}
}

// assertContainsAll asserts s contains every want substring.
func assertContainsAll(t *testing.T, s string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(s, w) {
			t.Errorf("expected content to contain %q\ngot:\n%s", w, s)
		}
	}
}

// TestCliInstallPrintsThePathAdviceForTheOperatorsOwnShell — an unprivileged
// install renders fish syntax for a fish operator and names that operator's
// own config.fish. fish is the case that cannot be faked by a generic export
// line: `export` is not a fish builtin, so the POSIX form pasted into fish is
// an error rather than a PATH change.
//
// $SHELL and $HOME are the subject here BECAUSE there is no elevation record.
// Mutation that reddens it: make operator_login_shell refuse whenever
// $SUDO_USER is unset — every unprivileged install would fall to the generic
// block and name no file.
func TestCliInstallPrintsThePathAdviceForTheOperatorsOwnShell(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	stageCliMigrations(t, staging)
	binDir := filepath.Join(home, ".local", "bin")

	cmd := exec.Command("sh", stagedCliInstaller(t, staging))
	cmd.Dir = staging
	cmd.Env = []string{
		"HOME=" + home,
		"PREFIX=" + filepath.Join(home, ".local"),
		"PATH=" + unprivilegedStubDir(t) + ":/usr/bin:/bin",
		"SHELL=/opt/homebrew/bin/fish",
		"LAUNCHD_DIR=" + filepath.Join(home, "no-launchd"),
		"SYSTEMD_DIR=" + filepath.Join(home, "no-systemd"),
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("install.sh failed: %v\n%s", err, out)
	}
	assertContainsAll(t, string(out),
		"==> Next steps",
		"burrowee's commands are in "+binDir+", which is not on your PATH.",
		"    set -gx PATH "+binDir+" $PATH",
		"    fish_add_path "+binDir,
		filepath.Join(home, ".config", "fish", "config.fish"),
		"  Then:  burrowee help",
	)
	if strings.Contains(string(out), "export PATH=") {
		t.Errorf("the POSIX export line was rendered for a fish operator — it is not a fish builtin:\n%s", out)
	}
	if strings.Contains(string(out), "is not on PATH — add:") {
		t.Errorf("the old one-line note survived:\n%s", out)
	}
}

// TestCliInstallIsSilentWhenTheDirIsAlreadyOnPath — the `case ":$PATH:"` guard
// is BACK for the two unprivileged installers, and only for them.
//
// The root installers print unconditionally because under `sudo` they see
// root's secure_path and cannot observe the operator's interactive PATH: the
// question is unanswerable there, so it must not be guessed. THIS installer
// runs as the operator — the process IS their shell and $PATH is theirs — so
// the answer is exact, and printing "which is not on your PATH" at a directory
// that demonstrably is on it tells them something false.
//
// Dropping the guard here was a real regression in the first cut of this
// change: the justification written into the comment ("under sudo this process
// sees root's secure_path") is true of the installers it was copied FROM and
// false of this one.
//
// Mutation that reddens it: remove the guard again.
func TestCliInstallIsSilentWhenTheDirIsAlreadyOnPath(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)
	stageCliMigrations(t, staging)
	binDir := filepath.Join(home, ".local", "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command("sh", stagedCliInstaller(t, staging))
	cmd.Dir = staging
	cmd.Env = []string{
		"HOME=" + home,
		"PREFIX=" + filepath.Join(home, ".local"),
		"PATH=" + binDir + ":" + unprivilegedStubDir(t) + ":/usr/bin:/bin",
		"SHELL=/bin/zsh",
		"LAUNCHD_DIR=" + filepath.Join(home, "no-launchd"),
		"SYSTEMD_DIR=" + filepath.Join(home, "no-systemd"),
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("install.sh failed: %v\n%s", err, out)
	}
	if strings.Contains(string(out), "==> Next steps") {
		t.Errorf("the advice was printed although %s is already on this shell's PATH:\n%s", binDir, out)
	}
	if strings.Contains(string(out), "which is not on your PATH") {
		t.Errorf("the install told the operator a directory on their PATH is not on it:\n%s", out)
	}
}

// TestAgentInstallPrintsThePathAdvice — the agent's vendored copy of the
// renderer produces the same block. It has no migrations/ in its kit and so
// nothing to source; this is what stops the copy drifting unnoticed.
//
// Mutation that reddens it: delete the vendored renderer, or leave the old
// one-line note in place beside it.
func TestAgentInstallPrintsThePathAdvice(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedAgentBins(t, staging)
	binDir := filepath.Join(home, ".local", "bin")

	cmd := exec.Command("sh", agentInstallShPath(t))
	cmd.Dir = staging
	cmd.Env = []string{
		"HOME=" + home,
		"PREFIX=" + filepath.Join(home, ".local"),
		"PATH=" + unprivilegedStubDir(t) + ":/usr/bin:/bin",
		"SHELL=/bin/bash",
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("agent install.sh failed: %v\n%s", err, out)
	}
	assertContainsAll(t, string(out),
		"==> Next steps",
		"burrowee's commands are in "+binDir+", which is not on your PATH.",
		"    export PATH=\""+binDir+":$PATH\"",
		"  Then:  burrowee help",
	)
	if strings.Contains(string(out), "is not on PATH — add:") {
		t.Errorf("the old one-line note survived:\n%s", out)
	}
}

// nextStepsBlock returns everything from the "==> Next steps" marker to the end
// of the block, or "" when the output carries none.
func nextStepsBlock(t *testing.T, out string) string {
	t.Helper()
	i := strings.Index(out, "==> Next steps")
	if i < 0 {
		return ""
	}
	rest := out[i:]
	j := strings.Index(rest, "  Then:  burrowee help")
	if j < 0 {
		return rest
	}
	return rest[:j+len("  Then:  burrowee help")]
}

// unprivilegedStubDir returns a PATH dir whose `id -u` reports a NON-root uid.
//
// THE SUITE MUST NOT SELF-SELECT ON THE RUNNER'S EUID. render_path_advice
// resolves the subject from $SHELL/$HOME only when there is no elevation
// record AND the process is not root; at euid 0 with no $SUDO_USER it refuses,
// because a root login has no operator to advise. Run as root — which is how
// inner/edge and inner/gateway must run — every assertion below would silently
// measure the generic block instead of the shell-aware one, and would keep
// passing with the whole subject resolution reverted. That is the shape
// privilege.md calls "not a test".
//
// So the euid goes behind a seam and this suite drives the unprivileged value,
// exactly as the edge and gateway suites drive the privileged one with
// fakeRootUID. `go test ./inner/...` is then green in ONE environment rather
// than needing two.
func unprivilegedStubDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	writeUIDStub(t, dir, "501")
	return dir
}

// writeUIDStub drops an `id` reporting uid into dir, passing everything else
// through to the real one.
func writeUIDStub(t *testing.T, dir, uid string) {
	t.Helper()
	body := "#!/bin/sh\nif [ \"$1\" = \"-u\" ]; then echo " + uid + "; else /usr/bin/id \"$@\"; fi\n"
	if err := os.WriteFile(filepath.Join(dir, "id"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}

// unameStubDir returns a PATH dir whose `uname -s` answers goos and whose
// `id -u` reports a non-root uid, and which passes everything else through.
//
// THE BASH ARM IS THE ONLY ONE THAT BRANCHES ON THE PLATFORM: a macOS login
// shell reads .bash_profile and never .profile, a Linux one reads .profile.
// Without this stub the comparison below exercises whichever arm the runner
// happens to be, so a drift confined to the OTHER arm ships green — and CI is
// Linux while the reported host was a Mac, which is the worst possible split.
// The shared library already seams this
// (TestPathAdviceRendersBashProfilePerPlatform in the edge suite); the vendored
// copy needs the same seam or its bash rendering is half-unmeasured.
func unameStubDir(t *testing.T, goos string) string {
	t.Helper()
	dir := t.TempDir()
	body := "#!/bin/sh\nif [ \"$1\" = \"-s\" ]; then echo " + goos + "; else /usr/bin/uname \"$@\"; fi\n"
	if err := os.WriteFile(filepath.Join(dir, "uname"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	writeUIDStub(t, dir, "501")
	return dir
}

// TestAgentsVendoredRendererMatchesTheSharedOne — the drift guard for the copy.
//
// The agent kit carries no migrations/ (tools/payload.sh stages one only for
// the components takes_shared_ladder names), so its renderer is a hand copy of
// the shared library's, and a hand copy of anything in this codebase is the
// drift class that has already cost this project a byte-pinned region and a
// digest in two repos. There is no sentinel to pin here — the agent's copy is
// deliberately smaller, since it never resolves an elevation record — so the
// guard is behavioural: on one fixture host, under one login shell, the two
// installers must print the SAME block, byte for byte.
//
// BOTH PLATFORM ARMS ARE DRIVEN, not just the runner's. bash is the only
// rendering that branches on `uname -s`, so a stub pins each half in turn;
// every other shell is asserted under both and must be identical regardless,
// which also catches a copy that started consulting the platform where the
// original does not.
//
// Both runs share a $HOME on purpose: the block interpolates the bin dir and
// the profile path, so two homes would differ for a reason that is not drift.
//
// Mutation that reddens it: change a word in either copy — including a word
// that appears only in the .bash_profile line, which is what this seam adds.
func TestAgentsVendoredRendererMatchesTheSharedOne(t *testing.T) {
	shells := []string{"/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish", "/usr/bin/ksh"}
	for _, goos := range []string{"Darwin", "Linux"} {
		for _, shell := range shells {
			t.Run(goos+"/"+filepath.Base(shell), func(t *testing.T) {
				runVendoredRendererComparison(t, goos, shell)
			})
		}
	}
}

func runVendoredRendererComparison(t *testing.T, goos, shell string) {
	t.Helper()
	{
		{
			home := t.TempDir()
			env := []string{
				"HOME=" + home,
				"PREFIX=" + filepath.Join(home, ".local"),
				"PATH=" + unameStubDir(t, goos) + ":/usr/bin:/bin",
				"SHELL=" + shell,
				"LAUNCHD_DIR=" + filepath.Join(home, "no-launchd"),
				"SYSTEMD_DIR=" + filepath.Join(home, "no-systemd"),
			}

			cliStaging := t.TempDir()
			seedCliBins(t, cliStaging)
			stageCliMigrations(t, cliStaging)
			cliCmd := exec.Command("sh", stagedCliInstaller(t, cliStaging))
			cliCmd.Dir = cliStaging
			cliCmd.Env = env
			cliOut, err := cliCmd.CombinedOutput()
			if err != nil {
				t.Fatalf("cli install.sh failed: %v\n%s", err, cliOut)
			}

			agentStaging := t.TempDir()
			seedAgentBins(t, agentStaging)
			agentCmd := exec.Command("sh", agentInstallShPath(t))
			agentCmd.Dir = agentStaging
			agentCmd.Env = env
			agentOut, err := agentCmd.CombinedOutput()
			if err != nil {
				t.Fatalf("agent install.sh failed: %v\n%s", err, agentOut)
			}

			shared := nextStepsBlock(t, string(cliOut))
			vendored := nextStepsBlock(t, string(agentOut))
			if shared == "" {
				t.Fatalf("the cli printed no Next steps block:\n%s", cliOut)
			}
			if vendored != shared {
				t.Errorf("the agent's vendored renderer has drifted from the shared one.\nshared:\n%s\n\nvendored:\n%s", shared, vendored)
			}
			// The stub has to be REACHED, or every arm above compares the
			// runner's own platform twice and the seam is decoration.
			if filepath.Base(shell) == "bash" {
				wantProfile := ".profile"
				if goos == "Darwin" {
					wantProfile = ".bash_profile"
				}
				if !strings.Contains(shared, filepath.Join(home, wantProfile)) {
					t.Errorf("the %s bash rendering does not name %s — the uname stub was not consulted:\n%s", goos, wantProfile, shared)
				}
			}
		}
	}
}
