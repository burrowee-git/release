package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestLinksAreDeferredWhileALoadedUnitStillNamesTheLinkPath — the 0.2 → 0.3
// ordering hazard. On a 0.2 host the unit the supervisor is running names
// /usr/local/bin/burrowee-gateway (the link path) as its program AND, on
// macOS, as a KeepAlive.PathState watch. link_operator_bins replaces that
// path in place, so making the link before the 0.3 units are loaded can bounce
// the daemon onto the 0.3 binary under the 0.2 unit, and a rollback then
// points the restored 0.2 unit at a dangling link. The installer must see the
// on-disk unit BEFORE render_units, make no link, say so, and leave the links
// to the guard's post-restart housekeeping.
//
// Mutation that reddens it: drop links_deferred_to_guard (link unconditionally
// after render_units) — the links appear and the note does not.
func TestLinksAreDeferredWhileALoadedUnitStillNamesTheLinkPath(t *testing.T) {
	home := t.TempDir()
	stub := linkingStub(t, home)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	if err := os.MkdirAll(linkDir(home), 0o755); err != nil {
		t.Fatal(err)
	}
	// The 0.2 units, exactly as a host that has not crossed yet carries them:
	// both init flavours, so the predicate is exercised whichever one the stub
	// renders for.
	units := []struct{ dir, name, body string }{
		{systemdDir(home), "burrowee-gateway.service", "[Service]\nExecStart=" + filepath.Join(linkDir(home), "burrowee-gateway") + " --config-dir /usr/local/etc/burrowee/gateway\n"},
		{launchdDir(home), "com.burrowee.gateway.plist", "<plist><dict><key>ProgramArguments</key><array><string>" + filepath.Join(linkDir(home), "burrowee-gateway") + "</string></array></dict></plist>\n"},
	}
	for _, u := range units {
		if err := os.MkdirAll(u.dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(u.dir, u.name), []byte(u.body), 0o644); err != nil {
			t.Fatal(err)
		}
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
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("links were made while a loaded 0.2 unit still named the link path: %v", names)
	}
	if !strings.Contains(out, "follow the restart") {
		t.Errorf("the installer did not say the links were deferred:\n%s", out)
	}
}
