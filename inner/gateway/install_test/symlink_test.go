// symlink_test.go — the /usr/local/bin symlinks, spec §6.1's four rules.
//
// The binaries an operator TYPES are linked into /usr/local/bin so that
// `burrowee-gateway-cli …` keeps working with no PATH change after the exec
// root moved to /usr/local/burrowee/bin. Four rules, one test each, plus the
// negative half of rule 2:
//
//  1. Nothing root execs ever names a link — units name the real path.
//  2. Link only into a root-secure directory; otherwise create NO link and
//     print the one line that adds the exec root to PATH.
//  3. Created as root, replacing whatever is there: rm -f then ln -sfn,
//     never a write THROUGH an existing link or file.
//  4. Removed on uninstall, and only when the link still points into our
//     tree.
//
// BURROWEE_LINK_DIR is the test-only seam for /usr/local/bin, set by
// installShEnv like every other seam so no test here can reach the real
// directory. The positive cases need the seamed directory to READ as
// root-secure while being writable by this unprivileged process — the same
// fakeRootUID + real-modes stat stub system_tree_test.go uses.
package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// operatorTypedBins is install.sh's LINK_BINS — the names an operator types.
// burrowee-gateway-console, burrowee-gateway-updater and burrowee-register
// are spawned by a root parent that names the real path (rule 1) and get no
// link; they are what the 0.2→0.3 rung's sweep of /usr/local/bin removes.
var operatorTypedBins = []string{"burrowee", "burrowee-gateway", "burrowee-gateway-cli"}

// linkingStub is stubInitSystem plus the two stubs that let an unprivileged
// process take the root-secure branch against its own sandbox: `id -u`
// reporting 0 and a stat reporting uid 0 with the REAL modes under home.
func linkingStub(t *testing.T, home string) string {
	t.Helper()
	stub := stubInitSystem(t)
	fakeRootUID(t, stub)
	statStubRootUIDRealModes(t, stub, home)
	return stub
}

// TestLinksAreCreatedWhenTheLinkDirIsRootSecure — rule 2, positive. A
// root-owned 0755 link directory gets one symlink per operator-typed name,
// each resolving into $BIN_DIR, and nothing else.
//
// Mutation that reddens it: delete the ln -sfn.
func TestLinksAreCreatedWhenTheLinkDirIsRootSecure(t *testing.T) {
	home := t.TempDir()
	stub := linkingStub(t, home)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	if err := os.MkdirAll(linkDir(home), 0o755); err != nil {
		t.Fatal(err)
	}

	out, err := runStaged(t, installShPath(t), staging, home, stub)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	for _, b := range operatorTypedBins {
		link := filepath.Join(linkDir(home), b)
		target, readErr := os.Readlink(link)
		if readErr != nil {
			t.Errorf("%s is not a symlink: %v", link, readErr)
			continue
		}
		if want := filepath.Join(binDir(home), b); target != want {
			t.Errorf("%s -> %s, want %s", link, target, want)
		}
	}
	entries, readErr := os.ReadDir(linkDir(home))
	if readErr != nil {
		t.Fatal(readErr)
	}
	if len(entries) != len(operatorTypedBins) {
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("link dir holds %v, want exactly the operator-typed names %v — a root-spawned binary must not be linked", names, operatorTypedBins)
	}
	if strings.Contains(out, `export PATH="`) {
		t.Errorf("the PATH hint was printed although the links were created:\n%s", out)
	}
}

// TestNoLinkIsCreatedWhenTheLinkDirIsNotRootSecure — rule 2, negative, and
// the reason the rule exists: unlink is governed by write permission on the
// CONTAINING directory, so in a Homebrew-owned /usr/local/bin any user can
// delete root's link and drop their own file at that name, and the
// operator's next `sudo burrowee-gateway-cli` runs it as root. So: zero
// entries, and the one PATH line instead.
//
// Mutation that reddens it: drop the dir_is_root_secure gate.
func TestNoLinkIsCreatedWhenTheLinkDirIsNotRootSecure(t *testing.T) {
	home := t.TempDir()
	stub := linkingStub(t, home)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	if err := os.MkdirAll(linkDir(home), 0o775); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(linkDir(home), 0o775); err != nil {
		t.Fatal(err)
	}

	out, err := runStaged(t, installShPath(t), staging, home, stub)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	entries, readErr := os.ReadDir(linkDir(home))
	if readErr != nil {
		t.Fatal(readErr)
	}
	if len(entries) != 0 {
		t.Errorf("a link was created in a group-writable directory: %v", entries)
	}
	assertContains(t, out, `export PATH="`+binDir(home)+`:$PATH"`, linkDir(home))
}

// TestARealFileAtTheLinkPathIsReplacedNotWrittenThrough — rule 3. Every 0.2
// host carries a REAL /usr/local/bin/burrowee-gateway-cli, and `ln -sfn`
// onto an existing symlink writes through it while onto a regular file it
// needs the rm -f first — a stale regular file left in place shadows the new
// install completely.
//
// Mutation that reddens it: drop the rm -f and keep only ln -sfn (ln -sfn
// replaces a plain file too on some platforms, so the assertion is on the
// BYTES being gone, not merely on a symlink existing — a write through the
// old file would leave them).
func TestARealFileAtTheLinkPathIsReplacedNotWrittenThrough(t *testing.T) {
	home := t.TempDir()
	stub := linkingStub(t, home)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	if err := os.MkdirAll(linkDir(home), 0o755); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(linkDir(home), "burrowee-gateway-cli")
	if err := os.WriteFile(stale, []byte("#!/bin/sh\necho STALE-0.2-CLI\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	// And an existing symlink pointing ELSEWHERE for another name: a write
	// through it would land in that other file.
	elsewhere := filepath.Join(t.TempDir(), "elsewhere-burrowee")
	if err := os.WriteFile(elsewhere, []byte("elsewhere\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, filepath.Join(linkDir(home), "burrowee")); err != nil {
		t.Fatal(err)
	}

	out, err := runStaged(t, installShPath(t), staging, home, stub)
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	if target, readErr := os.Readlink(stale); readErr != nil {
		t.Errorf("%s is still a regular file after the install: %v", stale, readErr)
	} else if want := filepath.Join(binDir(home), "burrowee-gateway-cli"); target != want {
		t.Errorf("%s -> %s, want %s", stale, target, want)
	}
	if got := readFile(t, filepath.Join(binDir(home), "burrowee-gateway-cli")); strings.Contains(got, "STALE") {
		t.Errorf("the stale file's bytes reached $BIN_DIR — the link was written through:\n%s", got)
	}
	if got := readFile(t, elsewhere); got != "elsewhere\n" {
		t.Errorf("the pre-existing symlink's target was written through: %q", got)
	}
	if target, readErr := os.Readlink(filepath.Join(linkDir(home), "burrowee")); readErr != nil || target != filepath.Join(binDir(home), "burrowee") {
		t.Errorf("the foreign symlink was not replaced by ours: target=%q err=%v", target, readErr)
	}
}

// TestNoRenderedUnitNamesALink — rule 1. ProgramArguments / ExecStart /
// KeepAlive.PathState / StandardOutPath name $BIN_DIR paths and never the
// link directory. The link exists for humans; root execs the real path.
//
// Mutation that reddens it: render `$LINK_DIR/burrowee-gateway` into either
// unit.
func TestNoRenderedUnitNamesALink(t *testing.T) {
	for _, goos := range forcedOSes {
		t.Run(goos, func(t *testing.T) {
			home := t.TempDir()
			stub := stubInitSystemFor(t, goos)
			seedMigrateCapableCLI(t, home)
			if err := os.MkdirAll(linkDir(home), 0o755); err != nil {
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
				if strings.Contains(body, linkDir(home)) {
					t.Errorf("%s names the link directory %s — root would exec a path a non-root user may be able to replace:\n%s", unit, linkDir(home), body)
				}
			}
		})
	}
}

// TestUninstallRemovesOnlyOurOwnLinks — rule 4. One link of ours, one
// foreign symlink at a linkable name, one regular file at another: only ours
// goes.
//
// Mutation that reddens it: drop the target-under-$BIN_DIR check.
func TestUninstallRemovesOnlyOurOwnLinks(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	seedMigrateCapableCLI(t, home)
	if err := os.MkdirAll(linkDir(home), 0o755); err != nil {
		t.Fatal(err)
	}
	ours := filepath.Join(linkDir(home), "burrowee-gateway-cli")
	if err := os.Symlink(filepath.Join(binDir(home), "burrowee-gateway-cli"), ours); err != nil {
		t.Fatal(err)
	}
	foreignTarget := filepath.Join(t.TempDir(), "operator-wrapper")
	if err := os.WriteFile(foreignTarget, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	foreign := filepath.Join(linkDir(home), "burrowee-gateway")
	if err := os.Symlink(foreignTarget, foreign); err != nil {
		t.Fatal(err)
	}
	regular := filepath.Join(linkDir(home), "burrowee")
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
