// symlink_test.go — the /usr/local/bin symlinks, spec §6.1's four rules, for
// the edge. The gateway's inner/gateway/install_test/symlink_test.go carries
// the reasoning; this is the same five claims against edge's LINK_BINS
// (burrowee, burrowee-edge, burrowee-edge-cli — never burrowee-edge-updater,
// which its unit execs by real path).
package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var edgeOperatorTypedBins = []string{"burrowee", "burrowee-edge", "burrowee-edge-cli"}

// linkingStub is stubRootEnv plus a stat reporting uid 0 with the real
// modes, so the sandboxed link directory can READ as root-secure.
func linkingStub(t *testing.T, sb sandbox) string {
	t.Helper()
	stub := stubRootEnv(t)
	edgeStatStubRootUIDRealModes(t, stub, sb.home)
	return stub
}

// TestEdgeLinksAreCreatedWhenTheLinkDirIsRootSecure — rule 2, positive.
// Mutation that reddens it: delete the ln -sfn.
func TestEdgeLinksAreCreatedWhenTheLinkDirIsRootSecure(t *testing.T) {
	sb := newSandbox(t)
	link := edgeLinkDir(sb.home)
	if err := os.MkdirAll(link, 0o755); err != nil {
		t.Fatal(err)
	}
	out, err := sb.run(t, "sh", linkingStub(t, sb), "STUB_UPDATER_OPTED_IN=1")
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	for _, b := range edgeOperatorTypedBins {
		target, readErr := os.Readlink(filepath.Join(link, b))
		if readErr != nil {
			t.Errorf("%s/%s is not a symlink: %v", link, b, readErr)
			continue
		}
		if want := filepath.Join(sb.sysBinDir, b); target != want {
			t.Errorf("%s/%s -> %s, want %s", link, b, target, want)
		}
	}
	entries, readErr := os.ReadDir(link)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if len(entries) != len(edgeOperatorTypedBins) {
		t.Errorf("link dir holds %d entries, want exactly %v — the updater must not be linked", len(entries), edgeOperatorTypedBins)
	}
	if strings.Contains(out, `export PATH="`) {
		t.Errorf("the PATH hint was printed although the links were created:\n%s", out)
	}
}

// TestEdgeNoLinkIsCreatedWhenTheLinkDirIsNotRootSecure — rule 2, negative:
// a group-writable link directory gets zero entries and the one PATH line.
// Mutation that reddens it: drop the dir_is_root_secure gate.
func TestEdgeNoLinkIsCreatedWhenTheLinkDirIsNotRootSecure(t *testing.T) {
	sb := newSandbox(t)
	link := edgeLinkDir(sb.home)
	if err := os.MkdirAll(link, 0o775); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(link, 0o775); err != nil {
		t.Fatal(err)
	}
	out, err := sb.run(t, "sh", linkingStub(t, sb), "STUB_UPDATER_OPTED_IN=1")
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	entries, readErr := os.ReadDir(link)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if len(entries) != 0 {
		t.Errorf("a link was created in a group-writable directory: %v", entries)
	}
	assertContains(t, out, `export PATH="`+sb.sysBinDir+`:$PATH"`, link)
}

// TestEdgeARealFileAtTheLinkPathIsReplacedNotWrittenThrough — rule 3: every
// 0.2 host carries a REAL /usr/local/bin/burrowee-edge-cli.
func TestEdgeARealFileAtTheLinkPathIsReplacedNotWrittenThrough(t *testing.T) {
	sb := newSandbox(t)
	link := edgeLinkDir(sb.home)
	if err := os.MkdirAll(link, 0o755); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(link, "burrowee-edge-cli")
	if err := os.WriteFile(stale, []byte("#!/bin/sh\necho STALE-0.2-CLI\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	elsewhere := filepath.Join(t.TempDir(), "elsewhere-burrowee")
	if err := os.WriteFile(elsewhere, []byte("elsewhere\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, filepath.Join(link, "burrowee")); err != nil {
		t.Fatal(err)
	}
	out, err := sb.run(t, "sh", linkingStub(t, sb), "STUB_UPDATER_OPTED_IN=1")
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	if target, readErr := os.Readlink(stale); readErr != nil {
		t.Errorf("%s is still a regular file after the install: %v", stale, readErr)
	} else if want := filepath.Join(sb.sysBinDir, "burrowee-edge-cli"); target != want {
		t.Errorf("%s -> %s, want %s", stale, target, want)
	}
	if got := readFile(t, filepath.Join(sb.sysBinDir, "burrowee-edge-cli")); strings.Contains(got, "STALE") {
		t.Errorf("the stale file's bytes reached $BIN_DIR — the link was written through:\n%s", got)
	}
	if got := readFile(t, elsewhere); got != "elsewhere\n" {
		t.Errorf("the pre-existing symlink's target was written through: %q", got)
	}
}

// TestEdgeNoRenderedUnitNamesALink — rule 1: both units name $SYS_BIN_DIR,
// never the link directory. Mutation that reddens it: render
// `$LINK_DIR/burrowee-edge` into either unit.
func TestEdgeNoRenderedUnitNamesALink(t *testing.T) {
	sb := newSandbox(t)
	link := edgeLinkDir(sb.home)
	if err := os.MkdirAll(link, 0o755); err != nil {
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
		if strings.Contains(body, link) {
			t.Errorf("%s names the link directory %s — root would exec a path a non-root user may be able to replace:\n%s", unit, link, body)
		}
	}
}

// TestEdgeUninstallRemovesOnlyOurOwnLinks — rule 4. Mutation that reddens
// it: drop the target-under-$BIN_DIR check.
func TestEdgeUninstallRemovesOnlyOurOwnLinks(t *testing.T) {
	sb := newSandbox(t)
	link := edgeLinkDir(sb.home)
	if err := os.MkdirAll(link, 0o755); err != nil {
		t.Fatal(err)
	}
	ours := filepath.Join(link, "burrowee-edge-cli")
	if err := os.Symlink(filepath.Join(sb.sysBinDir, "burrowee-edge-cli"), ours); err != nil {
		t.Fatal(err)
	}
	foreignTarget := filepath.Join(t.TempDir(), "operator-wrapper")
	if err := os.WriteFile(foreignTarget, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	foreign := filepath.Join(link, "burrowee-edge")
	if err := os.Symlink(foreignTarget, foreign); err != nil {
		t.Fatal(err)
	}
	regular := filepath.Join(link, "burrowee")
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
