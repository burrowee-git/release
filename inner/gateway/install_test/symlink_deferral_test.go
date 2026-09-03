// symlink_deferral_test.go — the deferral is gone with the links, and this is
// the guard that keeps it gone.
//
// The 0.2 → 0.3 ordering hazard was real while a link step existed: on a 0.2
// host the unit the supervisor is running names /usr/local/bin/burrowee-gateway
// as its program AND, on macOS, as a KeepAlive.PathState watch.
// link_operator_bins replaced that path in place, so making the link before the
// 0.3 units were loaded could bounce the daemon onto the 0.3 binary under the
// 0.2 unit, and a rollback then pointed the restored 0.2 plist at a dangling
// link. The installer answered that by asking links_deferred_to_guard BEFORE
// render_units and handing the links to the guard's post-restart housekeeping.
//
// With no link to make there is nothing to defer, and the whole apparatus —
// the predicate, the LINKS_DEFERRED flag, the note, the guard's third
// sourced call — is deleted. What is asserted here is the OUTCOME on exactly
// that host: a 0.2 unit on disk naming the legacy path changes nothing about
// what this install writes there, which is still nothing, and no deferral note
// is printed.
//
// Mutation that reddens it: bring link_operator_bins back, with or without the
// deferral.
package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestA02UnitNamingTheLegacyPathChangesNothing(t *testing.T) {
	home := t.TempDir()
	stub := linkingStub(t, home)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	legacy := legacyBinDir(home)
	if err := os.MkdirAll(legacy, 0o755); err != nil {
		t.Fatal(err)
	}
	// The 0.2 units, exactly as a host that has not crossed yet carries them:
	// both init flavours, so neither shape can be the one that slips through.
	units := []struct{ dir, name, body string }{
		{systemdDir(home), "burrowee-gateway.service", "[Service]\nExecStart=" + filepath.Join(legacy, "burrowee-gateway") + " --config-dir /usr/local/etc/burrowee/gateway\n"},
		{launchdDir(home), "com.burrowee.gateway.plist", "<plist><dict><key>ProgramArguments</key><array><string>" + filepath.Join(legacy, "burrowee-gateway") + "</string></array></dict></plist>\n"},
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
	entries, readErr := os.ReadDir(legacy)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if len(entries) != 0 {
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("the install wrote %v into %s on a host whose loaded units still name it", names, legacy)
	}
	if strings.Contains(out, "follow the restart") {
		t.Errorf("the installer still defers links to the guard — the deferral has no subject any more:\n%s", out)
	}
}
