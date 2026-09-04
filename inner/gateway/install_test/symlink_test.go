// symlink_test.go — there are no symlinks. This file asserts the ABSENCE of
// the step that used to make them, which is a claim that needs a test far more
// than the step ever did.
//
// 0.3 linked the operator-typed names into /usr/local/bin so
// `burrowee-gateway-cli …` kept working with no PATH change after the exec
// root moved to /usr/local/burrowee/bin. Rule 2 gated that on the directory
// being root-secure, for a reason that still holds exactly: `unlink` is
// governed by write permission on the CONTAINING directory, so in a
// Homebrew-owned /usr/local/bin any user can delete root's link and drop their
// own file at that name. What turned out to be false is that the gate would
// normally pass. On a clean modern Mac the directory does not exist; on a Mac
// where brew got there first it is brew's. So the refusal path was the normal
// path, and the normal outcome was an installed gateway with no command the
// operator could type.
//
// The step is deleted; every successful install prints an export line for the
// invoking operator's own shell instead (path_advice_test.go). Rules 2, 3 and
// 4 have no subject left. Rule 1 survives, now trivially — nothing root execs
// names a link, because no link exists — and is still asserted below, because
// "the units name $BIN_DIR" is a property of the renderers.
//
// BURROWEE_LEGACY_BIN_DIR is the test-only seam for /usr/local/bin, set by
// installShEnv like every other seam so no test here can reach the real
// directory. The positive cases still need the seamed system tree to READ as
// root-secure while being writable by this unprivileged process — the same
// fakeRootUID + real-modes stat stub system_tree_test.go uses.
package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// operatorTypedBins is install.sh's OPERATOR_BINS — the names an operator
// types, and now the sweep's whole candidate set in the 0.2 exec root.
// burrowee-gateway-console, burrowee-gateway-updater and burrowee-register are
// spawned by a root parent that names the real path (rule 1).
var operatorTypedBins = []string{"burrowee", "burrowee-gateway", "burrowee-gateway-cli"}

// linkingStub is stubInitSystem plus the two stubs that let an unprivileged
// process take the root-secure branch against its own sandbox: `id -u`
// reporting 0 and a stat reporting uid 0 with the REAL modes under home. It is
// named for what it once enabled; what it enables now is the ownership walk
// over the tree install.sh builds.
func linkingStub(t *testing.T, home string) string {
	t.Helper()
	stub := stubInitSystem(t)
	fakeRootUID(t, stub)
	statStubRootUIDRealModes(t, stub, home)
	return stub
}

// TestInstallPutsNothingInTheLegacyExecRoot — the invariant that replaced
// spec §6.1 rules 2, 3 and 4. A root-secure legacy directory is exactly the
// case the old step WOULD have linked into, so this is the strongest form of
// the claim: even where linking was safe and wanted, nothing is written there.
//
// Mutation that reddens it: put link_operator_bins back.
func TestInstallPutsNothingInTheLegacyExecRoot(t *testing.T) {
	home := t.TempDir()
	stub := linkingStub(t, home)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	legacy := legacyBinDir(home)
	if err := os.MkdirAll(legacy, 0o755); err != nil {
		t.Fatal(err)
	}

	out, err := runStaged(t, installShPath(t), staging, home, stub)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	entries, readErr := os.ReadDir(legacy)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if len(entries) != 0 {
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("the install wrote %v into %s — nothing may be placed there, linked or otherwise", names, legacy)
	}
	if strings.Contains(out, "linked into") {
		t.Errorf("the install reported making links:\n%s", out)
	}
}

// TestInstallLeavesAnOperatorsOwnFilesInTheLegacyExecRoot — the same invariant
// from the other side. Rule 3 REPLACED whatever sat at an operator-typed name
// (rm -f, then ln -sfn), which was correct while something was being put there
// and is now a destructive act with no purpose.
//
// The stale-exec-root sweep is a different question, answered by the shared
// library and its own suite: it removes a file only on positive evidence that
// it is a burrowee build with a trusted twin, and neither fixture here carries
// a burrowee build stamp.
//
// Mutation that reddens it: put link_operator_bins back — it would replace
// both.
func TestInstallLeavesAnOperatorsOwnFilesInTheLegacyExecRoot(t *testing.T) {
	home := t.TempDir()
	stub := linkingStub(t, home)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	legacy := legacyBinDir(home)
	if err := os.MkdirAll(legacy, 0o755); err != nil {
		t.Fatal(err)
	}
	theirFile := filepath.Join(legacy, "burrowee-gateway-cli")
	if err := os.WriteFile(theirFile, []byte("#!/bin/sh\necho operator's own wrapper\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	elsewhere := filepath.Join(t.TempDir(), "elsewhere-burrowee")
	if err := os.WriteFile(elsewhere, []byte("elsewhere\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	theirLink := filepath.Join(legacy, "burrowee")
	if err := os.Symlink(elsewhere, theirLink); err != nil {
		t.Fatal(err)
	}

	out, err := runStaged(t, installShPath(t), staging, home, stub)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	if got := readFile(t, theirFile); !strings.Contains(got, "operator's own wrapper") {
		t.Errorf("%s was replaced by the install: %q", theirFile, got)
	}
	target, readErr := os.Readlink(theirLink)
	if readErr != nil {
		t.Errorf("%s is no longer a symlink: %v", theirLink, readErr)
	} else if target != elsewhere {
		t.Errorf("%s -> %s, want the operator's own target %s", theirLink, target, elsewhere)
	}
	if got := readFile(t, elsewhere); got != "elsewhere\n" {
		t.Errorf("the operator's symlink was written THROUGH: %q", got)
	}
}

// TestNoRenderedUnitNamesTheLegacyExecRoot — rule 1, the one that survives.
// ProgramArguments / ExecStart / KeepAlive.PathState / StandardOutPath name
// $BIN_DIR paths and never the 0.2 exec root.
//
// Mutation that reddens it: render `$LEGACY_BIN_DIR/burrowee-gateway` into
// either unit.
func TestNoRenderedUnitNamesTheLegacyExecRoot(t *testing.T) {
	for _, goos := range forcedOSes {
		t.Run(goos, func(t *testing.T) {
			home := t.TempDir()
			stub := stubInitSystemFor(t, goos)
			seedMigrateCapableCLI(t, home)
			if err := os.MkdirAll(legacyBinDir(home), 0o755); err != nil {
				t.Fatal(err)
			}

			runInstallSh(t, home, stub, "BURROWEE_UNITS_ONLY=1")

			units := []string{
				filepath.Join(systemdDir(home), "burrowee-gateway.service"),
				filepath.Join(systemdDir(home), "burrowee-gateway-updater.service"),
			}
			if goos == "darwin" {
				units = []string{
					filepath.Join(launchdDir(home), "com.burrowee.gateway.plist"),
					filepath.Join(launchdDir(home), "com.burrowee.gateway.updater.plist"),
				}
			}
			for _, unit := range units {
				body := readFile(t, unit)
				if !strings.Contains(body, binDir(home)+"/burrowee-gateway") {
					t.Errorf("%s does not name the real path under %s:\n%s", unit, binDir(home), body)
				}
				if strings.Contains(body, legacyBinDir(home)) {
					t.Errorf("%s names the 0.2 exec root %s — root would exec a path a non-root user may be able to replace:\n%s", unit, legacyBinDir(home), body)
				}
			}
		})
	}
}

// TestUninstallRemovesOnlyOurOwnDanglingLinks — the one thing an uninstall
// still has to do in the legacy exec root. No install makes a link there any
// more, but hosts that took a 0.3 release which DID are carrying them right
// now, and an uninstall that left them would leave a dangling name in a
// directory on the operator's PATH.
//
// One link of ours, one foreign symlink at a linkable name, one regular file
// at another: only ours goes.
//
// Mutation that reddens it: drop the target-under-$BIN_DIR check.
func TestUninstallRemovesOnlyOurOwnDanglingLinks(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)
	legacy := legacyBinDir(home)
	if err := os.MkdirAll(legacy, 0o755); err != nil {
		t.Fatal(err)
	}
	ours := filepath.Join(legacy, "burrowee-gateway-cli")
	if err := os.Symlink(filepath.Join(binDir(home), "burrowee-gateway-cli"), ours); err != nil {
		t.Fatal(err)
	}
	foreignTarget := filepath.Join(t.TempDir(), "operator-wrapper")
	if err := os.WriteFile(foreignTarget, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	foreign := filepath.Join(legacy, "burrowee-gateway")
	if err := os.Symlink(foreignTarget, foreign); err != nil {
		t.Fatal(err)
	}
	regular := filepath.Join(legacy, "burrowee")
	if err := os.WriteFile(regular, []byte("#!/bin/sh\necho operator's own\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	runInstallSh(t, home, stub, "BURROWEE_UNINSTALL=1")

	if _, err := os.Lstat(ours); err == nil {
		t.Errorf("our own link %s survived the uninstall", ours)
	}
	if _, err := os.Lstat(foreign); err != nil {
		t.Errorf("a symlink pointing outside our tree was removed: %v", err)
	}
	if _, err := os.Lstat(regular); err != nil {
		t.Errorf("a regular file at a linkable name was removed: %v", err)
	}
}
