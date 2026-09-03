// path_advice_test.go — the "Next steps" block that REPLACED the
// /usr/local/bin symlinks.
//
// 0.3 moved the exec root to /usr/local/burrowee/bin and the installers linked
// the operator-typed names back into /usr/local/bin wherever that directory
// proved root-secure. On a clean modern Mac it does not exist, so nothing was
// linked and the install ended with no command the operator could type. The
// link step is gone; what every installer prints instead is
// render_path_advice, authored once inside the byte-pinned SHARED SWEEP
// CONTRACT region of _shared/migrations/lib_stale_user_bins.sh so the gateway's
// copy of that library carries the identical function.
//
// THIS FILE DRIVES THE FUNCTION DIRECTLY, sourcing the library the way an
// installer does. The four shell renderings and the two ways a subject fails
// to resolve are decisions of the library, and proving them through a full
// sandboxed install would prove them once for edge and never for the gateway,
// the relay, the cli or the agent — all of which call the same function.
// TestEdgeInstallPrintsThePathAdvice below is the other half: that the
// installer makes the call at all, on the success path.
package install_test

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// adviceSubject is one seamed passwd entry: the account $SUDO_USER names, its
// home and its login shell, as the stubbed passwd database answers them.
type adviceSubject struct {
	user  string
	home  string
	shell string
}

// passwdStubDir builds a PATH dir whose getent answers for exactly one account
// and whose dscl answers for none — so the library's macOS branch cannot reach
// the REAL directory service of the machine this suite runs on. `id -u` reports
// uid, and `uname -s` reports goos.
//
// A subject with an empty user means "no account resolves": getent answers for
// nobody, which is the unresolvable case.
func passwdStubDir(t *testing.T, subj adviceSubject, uid, goos string) string {
	t.Helper()
	stub := t.TempDir()
	addPasswdStubs(t, stub, subj)
	stubBin(t, stub, "id", "#!/bin/sh\nif [ \"$1\" = \"-u\" ]; then echo "+uid+"; else /usr/bin/id \"$@\"; fi\n")
	stubBin(t, stub, "uname", "#!/bin/sh\nif [ \"$1\" = \"-s\" ]; then echo "+goos+"; else /usr/bin/uname \"$@\"; fi\n")
	return stub
}

// addPasswdStubs writes just the passwd-database half into an EXISTING stub
// PATH dir, so a full-install fixture can keep its own id/uname/systemctl stubs
// and still resolve one seamed account.
func addPasswdStubs(t *testing.T, stub string, subj adviceSubject) {
	t.Helper()
	getent := "#!/bin/sh\n" +
		"[ \"$1\" = passwd ] || exit 2\n" +
		"case \"$2\" in\n" +
		"'" + subj.user + "') [ -n \"$2\" ] || exit 2; printf '%s:x:1000:1000::%s:%s\\n' \"$2\" '" + subj.home + "' '" + subj.shell + "' ;;\n" +
		"*) exit 2 ;;\n" +
		"esac\n"
	stubBin(t, stub, "getent", getent)
	// dscl must never answer from the host: on a developer Mac it would resolve
	// a real account and the test would silently measure that machine's passwd
	// database instead of the fixture.
	stubBin(t, stub, "dscl", "#!/bin/sh\nexit 1\n")
}

// renderAdvice sources the shared library exactly as an installer does and
// calls render_path_advice with binDir, returning its stdout.
//
// HOME is a DECOY on every call in this file. Under `curl … | sudo sh` $HOME is
// root's, and an implementation that reached for it instead of resolving
// $SUDO_USER through the passwd database would name root's profile — the exact
// defect privilege.md §3.1 records. Every assertion below therefore also
// asserts the decoy is absent from the output.
const adviceDecoyHome = "/decoy-home-that-must-never-be-named"

func renderAdvice(t *testing.T, binDir string, stub string, sudoUser string, extraEnv ...string) string {
	t.Helper()
	shared := sharedMigrationsDir(t)
	script := ". \"$LIB_STALE_USER_BINS_DIR/lib_stale_user_bins.sh\"; render_path_advice \"$1\""
	cmd := exec.Command("sh", "-c", script, "sh", binDir)
	env := []string{
		"PATH=" + stub + ":/usr/bin:/bin",
		"HOME=" + adviceDecoyHome,
		"LIB_STALE_USER_BINS_DIR=" + shared,
		// /etc/passwd is the library's last-resort reader. The names used here
		// exist in no passwd file, so it answers nothing either way; setting
		// the seam explicitly keeps the fixture from depending on that.
		"LEGACY_HOME_PARENTS=/nonexistent-home-parents",
	}
	if sudoUser != "" {
		env = append(env, "SUDO_USER="+sudoUser)
	}
	env = append(env, extraEnv...)
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("render_path_advice failed: %v\n%s", err, out)
	}
	return string(out)
}

// assertLacks is assertContains' negative half.
func assertLacks(t *testing.T, s string, unwanted ...string) {
	t.Helper()
	for _, w := range unwanted {
		if strings.Contains(s, w) {
			t.Errorf("expected content NOT to contain %q\ngot:\n%s", w, s)
		}
	}
}

const adviceBinDir = "/usr/local/burrowee/bin"

// TestPathAdviceRendersTheOperatorsZshProfile — zsh, macOS's default and the
// shell of the host this whole project was reported against. The subject is
// $SUDO_USER resolved through the passwd database, never $HOME.
//
// Mutation that reddens it: read $HOME instead of home_of_user "$SUDO_USER".
func TestPathAdviceRendersTheOperatorsZshProfile(t *testing.T) {
	subj := adviceSubject{user: "opz", home: "/Users/opz", shell: "/bin/zsh"}
	out := renderAdvice(t, adviceBinDir, passwdStubDir(t, subj, "0", "Darwin"), subj.user)

	assertContains(t, out,
		"==> Next steps",
		"burrowee's commands are in "+adviceBinDir+", which is not on your PATH.",
		"    export PATH=\""+adviceBinDir+":$PATH\"",
		"    echo 'export PATH=\""+adviceBinDir+":$PATH\"' >> /Users/opz/.zprofile",
		"  Then:  burrowee help",
	)
	assertLacks(t, out, adviceDecoyHome)
}

// TestPathAdviceRendersBashProfilePerPlatform — a macOS login shell reads
// .bash_profile and never .profile; a Linux one reads .profile. One rendering
// with the wrong file is advice that silently does nothing at the next login.
//
// Mutation that reddens it: collapse the two branches onto one file name.
func TestPathAdviceRendersBashProfilePerPlatform(t *testing.T) {
	for _, tc := range []struct{ goos, profile string }{
		{"Darwin", "/Users/opb/.bash_profile"},
		{"Linux", "/Users/opb/.profile"},
	} {
		t.Run(tc.goos, func(t *testing.T) {
			subj := adviceSubject{user: "opb", home: "/Users/opb", shell: "/bin/bash"}
			out := renderAdvice(t, adviceBinDir, passwdStubDir(t, subj, "0", tc.goos), subj.user)
			assertContains(t, out,
				"    export PATH=\""+adviceBinDir+":$PATH\"",
				"    echo 'export PATH=\""+adviceBinDir+":$PATH\"' >> "+tc.profile,
			)
			assertLacks(t, out, adviceDecoyHome)
		})
	}
}

// TestPathAdviceRendersFishSyntaxAndNeverExport — fish shares no syntax with
// the other two: `export` is not a fish builtin, so the POSIX line pasted into
// fish is an error rather than a PATH change.
//
// Mutation that reddens it: drop the fish arm from the case.
func TestPathAdviceRendersFishSyntaxAndNeverExport(t *testing.T) {
	subj := adviceSubject{user: "opf", home: "/Users/opf", shell: "/opt/homebrew/bin/fish"}
	out := renderAdvice(t, adviceBinDir, passwdStubDir(t, subj, "0", "Darwin"), subj.user)

	assertContains(t, out,
		"    set -gx PATH "+adviceBinDir+" $PATH",
		"    fish_add_path "+adviceBinDir,
		"/Users/opf/.config/fish/config.fish",
	)
	assertLacks(t, out, "export PATH=", adviceDecoyHome)
}

// TestPathAdviceIsGenericForARootSessionWithNoOperator — $SUDO_USER unset at
// euid 0 is a genuine root login: nobody invoked it, so there is no operator to
// advise and no profile file that could be named. The export line still has to
// be there — that is the whole point of the block — but no file name is
// guessed.
//
// Mutation that reddens it: fall back to $HOME when $SUDO_USER is unset.
func TestPathAdviceIsGenericForARootSessionWithNoOperator(t *testing.T) {
	out := renderAdvice(t, adviceBinDir, passwdStubDir(t, adviceSubject{}, "0", "Darwin"), "")

	assertContains(t, out,
		"==> Next steps",
		"    export PATH=\""+adviceBinDir+":$PATH\"",
		"  Make it permanent by adding the line above to your shell's startup file.",
	)
	assertLacks(t, out, adviceDecoyHome, ".zprofile", ".bash_profile", ".profile", "config.fish")
}

// TestPathAdviceIsGenericWhenTheSubjectCannotBeResolved — $SUDO_USER names an
// account the passwd database does not answer for (a deleted user, an LDAP
// lookup that failed). Naming a guessed profile file for it would send the
// operator to edit something their shell never reads, so the block degrades to
// the generic form rather than inventing a subject.
//
// Mutation that reddens it: fall back to $SHELL/$HOME when the lookup fails.
func TestPathAdviceIsGenericWhenTheSubjectCannotBeResolved(t *testing.T) {
	stub := passwdStubDir(t, adviceSubject{user: "someone-else", home: "/Users/x", shell: "/bin/zsh"}, "0", "Darwin")
	out := renderAdvice(t, adviceBinDir, stub, "no-such-account-9x")

	assertContains(t, out,
		"    export PATH=\""+adviceBinDir+":$PATH\"",
		"  Make it permanent by adding the line above to your shell's startup file.",
	)
	assertLacks(t, out, adviceDecoyHome, ".zprofile", "/Users/x")
}

// TestPathAdviceUsesTheProcessOwnShellWhenUnprivileged — the cli and agent
// installers run with no elevation record at all, and there this process IS
// the operator: $SHELL and $HOME are exact and no passwd lookup is needed. The
// bin dir is theirs too, not the system exec root.
//
// Mutation that reddens it: return non-zero from operator_login_shell whenever
// $SUDO_USER is unset — which would leave every unprivileged install with the
// generic block and no profile named.
func TestPathAdviceUsesTheProcessOwnShellWhenUnprivileged(t *testing.T) {
	home := t.TempDir()
	binDir := filepath.Join(home, ".local", "bin")
	stub := passwdStubDir(t, adviceSubject{}, "501", "Darwin")
	out := renderAdvice(t, binDir, stub, "", "HOME="+home, "SHELL=/opt/homebrew/bin/fish")

	assertContains(t, out,
		"burrowee's commands are in "+binDir+", which is not on your PATH.",
		"    set -gx PATH "+binDir+" $PATH",
		"    fish_add_path "+binDir,
		filepath.Join(home, ".config", "fish", "config.fish"),
	)
	assertLacks(t, out, adviceDecoyHome)
}

// TestEdgeInstallPrintsThePathAdvice — the OTHER half: that a full sandboxed
// edge install actually makes the call, on the success path, with its own
// $BIN_DIR. What the block SAYS is the library's claim, proved above; what this
// asserts is that an install ends by saying it at all.
//
// The subject is a seamed passwd entry named by $SUDO_USER — the shape a real
// `curl … | sudo sh` has — and the sandbox's $HOME is root's stand-in, so an
// implementation reading $HOME would name a directory this assertion rejects.
//
// Mutation that reddens it: drop the print_path_advice call from install.sh.
func TestEdgeInstallPrintsThePathAdvice(t *testing.T) {
	sb := newSandbox(t)
	subj := adviceSubject{
		user:  "edge-operator",
		home:  filepath.Join(sb.home, "operator"),
		shell: "/bin/zsh",
	}
	stub := stubRootEnv(t)
	addPasswdStubs(t, stub, subj)

	out, err := sb.run(t, "sh", stub, "STUB_UPDATER_OPTED_IN=1", "SUDO_USER="+subj.user)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	assertContains(t, out,
		"==> Next steps",
		"burrowee's commands are in "+sb.sysBinDir+", which is not on your PATH.",
		"    export PATH=\""+sb.sysBinDir+":$PATH\"",
		"    echo 'export PATH=\""+sb.sysBinDir+":$PATH\"' >> "+filepath.Join(subj.home, ".zprofile"),
		"  Then:  burrowee help",
	)
}

// TestEdgeUpdaterInstallPrintsThePathAdvice — the recovery installer ends the
// same way. It places only burrowee-edge-updater, which nobody types, but it is
// still an install that leaves an operator at a prompt with an exec root that is
// on nobody's PATH — and it is the entry point reached precisely when the
// component's normal channel is broken.
//
// Mutation that reddens it: drop the print_path_advice call from
// updater.install.sh.
func TestEdgeUpdaterInstallPrintsThePathAdvice(t *testing.T) {
	f := newUpdaterFixture(t)
	stageMigrations(t, f.staging)
	operatorHome := filepath.Join(f.home, "operator")
	stub := stubRootEnv(t)
	addPasswdStubs(t, stub, adviceSubject{user: "edge-operator", home: operatorHome, shell: "/bin/zsh"})

	out, err := f.run(t, stub, "SUDO_USER=edge-operator", "STUB_UPDATER_OPTED_IN=1")
	if err != nil {
		t.Fatalf("updater.install.sh failed: %v\n%s", err, out)
	}
	assertContains(t, out,
		"==> Next steps",
		"burrowee's commands are in "+f.sysBinDir+", which is not on your PATH.",
		"    echo 'export PATH=\""+f.sysBinDir+":$PATH\"' >> "+filepath.Join(operatorHome, ".zprofile"),
	)
	assertLacks(t, out, "has no render_path_advice")
}

// TestEdgeUnitsOnlyPrintsThePathAdvice — the units-only reinstall is the run
// that SWEEPS, and a run that removes the operator's command owes them the
// replacement instruction more than a fresh install does.
//
// `burrowee edge service install` / LocalReinstall reach install.sh in this
// mode. It places no binaries, which is why it was originally read as "not an
// install" and left silent — but placement was never the test. This is the
// path that unlinks /usr/local/bin/burrowee-edge-cli and the shared `burrowee`
// dispatcher on a converging 0.2 host, so it was the one run that took the
// operator's typed command away and printed nothing about where it went.
//
// Mutation that reddens it: drop print_path_advice from the units-only branch.
func TestEdgeUnitsOnlyPrintsThePathAdvice(t *testing.T) {
	sb := newSandbox(t)
	subj := adviceSubject{
		user:  "edge-operator",
		home:  filepath.Join(sb.home, "operator"),
		shell: "/bin/zsh",
	}
	stub := stubRootEnv(t)
	addPasswdStubs(t, stub, subj)

	out, err := sb.run(t, "sh", stub,
		"STUB_UPDATER_OPTED_IN=1",
		"BURROWEE_UNITS_ONLY=1",
		"SUDO_USER="+subj.user)
	if err != nil {
		t.Fatalf("units-only reinstall failed: %v\n%s", err, out)
	}
	assertContains(t, out,
		"units-only reinstall",
		"==> Next steps",
		"    echo 'export PATH=\""+sb.sysBinDir+":$PATH\"' >> "+filepath.Join(subj.home, ".zprofile"),
	)
}
