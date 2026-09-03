// symlink_test.go — there are no symlinks. This file asserts the ABSENCE of
// the step that used to make them, which is a claim that needs a test far more
// than the step ever did.
//
// 0.3 linked the operator-typed names (burrowee, burrowee-edge,
// burrowee-edge-cli — never burrowee-edge-updater, which its unit execs by
// real path) from /usr/local/bin into $BIN_DIR wherever that directory proved
// root-secure. On a clean modern Mac /usr/local/bin does not exist, so nothing
// was linked and the install ended with no command the operator could type.
// The step is deleted; every install prints an export line for the invoking
// operator's own shell instead (path_advice_test.go).
//
// Of spec §6.1's four rules, only rule 1 survives, and only as a statement
// that is now trivially true: nothing root execs names a link, because no link
// exists. It is still asserted below, because "the units name $BIN_DIR" is a
// property of the renderers and would not stop being worth checking if
// somebody re-added a link step tomorrow.
package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var edgeOperatorTypedBins = []string{"burrowee", "burrowee-edge", "burrowee-edge-cli"}

// linkingStub is stubRootEnv plus a stat reporting uid 0 with the real modes,
// so the sandboxed system tree can READ as root-secure. It is named for what
// it once enabled; what it enables now is the ownership walk over the tree
// install.sh builds.
func linkingStub(t *testing.T, sb sandbox) string {
	t.Helper()
	stub := stubRootEnv(t)
	edgeStatStubRootUIDRealModes(t, stub, sb.home)
	return stub
}

// TestEdgeInstallPutsNothingInTheLegacyExecRoot — the invariant that replaced
// spec §6.1 rules 2, 3 and 4. A root-secure legacy directory is the case the
// old step would have LINKED into, so this is the strongest form of the claim:
// even where linking was safe and wanted, nothing is written there.
//
// Mutation that reddens it: put link_operator_bins back.
func TestEdgeInstallPutsNothingInTheLegacyExecRoot(t *testing.T) {
	sb := newSandbox(t)
	legacy := edgeLegacyBinDir(sb.home)
	if err := os.MkdirAll(legacy, 0o755); err != nil {
		t.Fatal(err)
	}
	out, err := sb.run(t, "sh", linkingStub(t, sb), "STUB_UPDATER_OPTED_IN=1")
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

// TestEdgeInstallLeavesAnOperatorsOwnFilesInTheLegacyExecRoot — the same
// invariant from the other side. The old step REPLACED whatever sat at an
// operator-typed name (rule 3: rm -f, then ln -sfn), which was correct while
// something was being put there and is now simply a destructive act with no
// purpose. An operator's own file at one of those names is theirs.
//
// The stale-exec-root sweep is a different question and is answered
// separately (exec_root_sweep_test.go): it removes a file only on positive
// evidence that it is a burrowee build with a trusted twin. The files here
// carry no burrowee build stamp, so no rule in this installer touches them.
//
// Mutation that reddens it: put link_operator_bins back — it would replace
// both.
func TestEdgeInstallLeavesAnOperatorsOwnFilesInTheLegacyExecRoot(t *testing.T) {
	sb := newSandbox(t)
	legacy := edgeLegacyBinDir(sb.home)
	if err := os.MkdirAll(legacy, 0o755); err != nil {
		t.Fatal(err)
	}
	theirFile := filepath.Join(legacy, "burrowee-edge-cli")
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

	out, err := sb.run(t, "sh", linkingStub(t, sb), "STUB_UPDATER_OPTED_IN=1")
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

// TestEdgeNoRenderedUnitNamesTheLegacyExecRoot — spec §6.1 rule 1, the one
// that survives. Both units name $SYS_BIN_DIR and never the 0.2 exec root.
//
// Mutation that reddens it: render `$LEGACY_BIN_DIR/burrowee-edge` into either
// unit.
func TestEdgeNoRenderedUnitNamesTheLegacyExecRoot(t *testing.T) {
	sb := newSandbox(t)
	legacy := edgeLegacyBinDir(sb.home)
	if err := os.MkdirAll(legacy, 0o755); err != nil {
		t.Fatal(err)
	}
	out, err := sb.run(t, "sh", stubRootEnv(t), "STUB_UPDATER_OPTED_IN=1")
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	for _, unit := range []string{"burrowee-edge.service", "burrowee-edge-updater.service"} {
		body := readFile(t, filepath.Join(sb.unitDir, unit))
		if !strings.Contains(body, sb.sysBinDir+"/burrowee-edge") {
			t.Errorf("%s does not name the real path under %s:\n%s", unit, sb.sysBinDir, body)
		}
		if strings.Contains(body, legacy) {
			t.Errorf("%s names the 0.2 exec root %s — root would exec a path a non-root user may be able to replace:\n%s", unit, legacy, body)
		}
	}
}

// TestEdgeUninstallRemovesOnlyOurOwnDanglingLinks — the one thing an uninstall
// still has to do in the legacy exec root. No install makes a link there any
// more, but hosts that took a 0.3 release which DID are carrying them right
// now, and an uninstall that left them would leave a dangling name in a
// directory on the operator's PATH.
//
// Three shapes, one outcome each: ours (a link into $BIN_DIR whose target this
// uninstall just removed) goes; a link pointing outside our tree is somebody
// else's and stays; a regular file at a linkable name is the operator's and
// stays.
//
// Mutation that reddens it: drop the target-under-$BIN_DIR check.
func TestEdgeUninstallRemovesOnlyOurOwnDanglingLinks(t *testing.T) {
	sb := newSandbox(t)
	legacy := edgeLegacyBinDir(sb.home)
	if err := os.MkdirAll(legacy, 0o755); err != nil {
		t.Fatal(err)
	}
	ours := filepath.Join(legacy, "burrowee-edge-cli")
	if err := os.Symlink(filepath.Join(sb.sysBinDir, "burrowee-edge-cli"), ours); err != nil {
		t.Fatal(err)
	}
	foreignTarget := filepath.Join(t.TempDir(), "operator-wrapper")
	if err := os.WriteFile(foreignTarget, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	foreign := filepath.Join(legacy, "burrowee-edge")
	if err := os.Symlink(foreignTarget, foreign); err != nil {
		t.Fatal(err)
	}
	regular := filepath.Join(legacy, "burrowee")
	if err := os.WriteFile(regular, []byte("#!/bin/sh\necho operator's own\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	out, err := sb.run(t, "sh", stubRootEnv(t), "BURROWEE_UNINSTALL=1")
	if err != nil {
		t.Fatalf("uninstall failed: %v\n%s", err, out)
	}
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
