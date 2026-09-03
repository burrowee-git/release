// exec_root_sweep_test.go — the installer's own call of the 0.2 exec-root
// sweep, after the units name the new tree.
//
// The shared ladder's sweep_stale_exec_root.sh rung runs BEFORE this
// installer re-renders the units, and while a 0.2 unit still names
// /usr/local/bin/burrowee-edge-updater the library correctly refuses to
// unlink a file a supervisor may be running. So the rung is a no-op on the
// first 0.3 install, and this call — after setup_root_service — is what
// actually clears the copies. The library's decisions are proved in
// tools/test-shared-migrations.sh (section 37); this asserts only that the
// installer makes the call at a point where it can succeed, and what it does
// to each of the three symlink shapes now that nothing links there any more.
package install_test

import (
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
)

// TestEdgeInstallSweepsTheStaleExecRootAfterTheUnitsMoved: a real (stamped)
// 0.2 copy of the updater in the legacy exec root is removed.
//
// Mutation that reddens it: drop the sweep_stale_exec_root call.
func TestEdgeInstallSweepsTheStaleExecRootAfterTheUnitsMoved(t *testing.T) {
	sb := newSandbox(t)
	legacy := filepath.Join(sb.home, "old-usr-local-bin")
	if err := os.MkdirAll(legacy, 0o755); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(legacy, "burrowee-edge-updater")
	if err := os.WriteFile(stale, []byte("#!/bin/sh\n# github.com/burrowee-git/edge/cmd/burrowee-edge-updater\necho old\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	me, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}

	out, runErr := sb.run(t, "sh", stubRootEnv(t),
		"STUB_UPDATER_OPTED_IN=1",
		"LEGACY_BIN_DIR="+legacy,
		"STALE_EXEC_ROOT_TWIN_OWNER="+me.Username)
	if runErr != nil {
		t.Fatalf("install failed: %v\n%s", runErr, out)
	}
	if _, statErr := os.Lstat(stale); statErr == nil {
		t.Errorf("the 0.2 updater copy survived at %s — the installer never swept the exec root:\n%s", stale, out)
	}
	if !strings.Contains(out, "removed stale 0.2 exec-root copy: "+stale) {
		t.Errorf("the sweep did not report the removal:\n%s", out)
	}
}

// TestEdgeInstallSweepsOurOwnSymlinksAndSparesEveryOther — the inversion.
//
// The sweep used to skip EVERY symlink in the legacy exec root, with the
// reason written in the library: "the 0.3 installer links the operator-typed
// names from /usr/local/bin into the new tree (spec §6.1); deleting one of
// those is deleting the install's PATH entry." Nothing links there any more,
// so that sentence is false and the carve-out now protects only stale state: a
// link into $BIN_DIR is one WE left on an earlier 0.3 install, it resolves to
// a binary the operator's PATH should be finding at $BIN_DIR anyway, and it
// sits in a directory an operator's PATH reaches ahead of the exec root.
//
// The three shapes, asserted separately because they are three different
// decisions:
//
//   - ours: a link whose target resolves inside $BIN_DIR — REMOVED.
//   - theirs: a link to anywhere else (an operator's own wrapper) — SPARED.
//   - dangling: a link whose target does not exist — SPARED, because a
//     resolution that cannot be made is not evidence of ownership, and
//     undecidable cases fail toward KEEP.
//
// Mutations that redden it, one per claim: skip every symlink again (ours
// survives); remove every symlink (theirs and the dangling one go); resolve a
// dangling link as ours (the dangling one goes).
func TestEdgeInstallSweepsOurOwnSymlinksAndSparesEveryOther(t *testing.T) {
	sb := newSandbox(t)
	legacy := filepath.Join(sb.home, "old-usr-local-bin")
	if err := os.MkdirAll(legacy, 0o755); err != nil {
		t.Fatal(err)
	}
	ours := filepath.Join(legacy, "burrowee")
	if err := os.Symlink(filepath.Join(sb.sysBinDir, "burrowee"), ours); err != nil {
		t.Fatal(err)
	}
	foreignTarget := filepath.Join(t.TempDir(), "operator-wrapper")
	if err := os.WriteFile(foreignTarget, []byte("#!/bin/sh\necho operator's own\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	theirs := filepath.Join(legacy, "burrowee-edge")
	if err := os.Symlink(foreignTarget, theirs); err != nil {
		t.Fatal(err)
	}
	dangling := filepath.Join(legacy, "burrowee-edge-cli")
	if err := os.Symlink(filepath.Join(t.TempDir(), "gone-long-ago"), dangling); err != nil {
		t.Fatal(err)
	}
	me, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}

	out, runErr := sb.run(t, "sh", stubRootEnv(t),
		"STUB_UPDATER_OPTED_IN=1",
		"LEGACY_BIN_DIR="+legacy,
		"STALE_EXEC_ROOT_TWIN_OWNER="+me.Username)
	if runErr != nil {
		t.Fatalf("install failed: %v\n%s", runErr, out)
	}
	if _, statErr := os.Lstat(ours); statErr == nil {
		t.Errorf("a symlink into %s survived — nothing links there any more, so it is stale state:\n%s", sb.sysBinDir, out)
	}
	if _, statErr := os.Lstat(theirs); statErr != nil {
		t.Errorf("a symlink pointing outside our tree was removed: %v\n%s", statErr, out)
	}
	if _, statErr := os.Lstat(dangling); statErr != nil {
		t.Errorf("a dangling symlink was removed — an unresolvable target is not evidence of ownership: %v\n%s", statErr, out)
	}
	assertContains(t, out,
		"removed stale 0.3 exec-root link: "+ours,
		"kept "+theirs+" — a symlink pointing outside",
		"kept "+dangling+" — a symlink whose target does not resolve",
	)
}

// TestEdgeInstallSweepsARealOperatorTypedCopyOnTheFirstRun — the second-order
// effect of deleting the keep-list, asserted rather than merely allowed.
//
// The installers used to hand the sweep every operator-typed name as "keep",
// because with nothing linked over them the real 0.2 file at each was the only
// copy anything reached by the absolute path. Nothing resolves by that path
// now, so the list is empty and a real 0.2 `burrowee-edge` under an
// operator-typed name is removed on the FIRST 0.3 run, where it used to be
// deferred to a later one.
//
// Mutation that reddens it: hand the sweep a keep-list again.
func TestEdgeInstallSweepsARealOperatorTypedCopyOnTheFirstRun(t *testing.T) {
	sb := newSandbox(t)
	legacy := filepath.Join(sb.home, "old-usr-local-bin")
	if err := os.MkdirAll(legacy, 0o755); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(legacy, "burrowee-edge")
	if err := os.WriteFile(stale, []byte("#!/bin/sh\n# github.com/burrowee-git/edge/cmd/burrowee-edge\necho 0.2\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	me, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}

	out, runErr := sb.run(t, "sh", stubRootEnv(t),
		"STUB_UPDATER_OPTED_IN=1",
		"LEGACY_BIN_DIR="+legacy,
		"STALE_EXEC_ROOT_TWIN_OWNER="+me.Username)
	if runErr != nil {
		t.Fatalf("install failed: %v\n%s", runErr, out)
	}
	if _, statErr := os.Lstat(stale); statErr == nil {
		t.Errorf("a real 0.2 copy at an operator-typed name survived the first 0.3 run — the keep-list is back:\n%s", out)
	}
	assertContains(t, out, "removed stale 0.2 exec-root copy: "+stale)
}
