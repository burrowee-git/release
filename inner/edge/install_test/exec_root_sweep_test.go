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
// installer makes the call at a point where it can succeed.
package install_test

import (
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
)

// TestEdgeInstallSweepsTheStaleExecRootAfterTheUnitsMoved: a real (stamped)
// 0.2 copy of the updater in the legacy exec root is removed; the symlink the
// installer made for burrowee-edge is not.
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
	link := filepath.Join(legacy, "burrowee-edge")
	if err := os.Symlink(filepath.Join(sb.sysBinDir, "burrowee-edge"), link); err != nil {
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
	if _, statErr := os.Lstat(link); statErr != nil {
		t.Errorf("the installer's own symlink was swept: %v", statErr)
	}
	if !strings.Contains(out, "removed stale 0.2 exec-root copy: "+stale) {
		t.Errorf("the sweep did not report the removal:\n%s", out)
	}
}
