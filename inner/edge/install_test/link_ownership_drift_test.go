// link_ownership_drift_test.go — the three copies of link_target_is_ours are
// byte-identical, or this fails.
//
// WHY THERE ARE THREE. The sweep (in the shared library) and the uninstall (in
// each system installer) must not disagree about which links in the 0.2 exec
// root are ours: one removing a link the other would spare is the same defect
// read from two directions. They cannot share one definition, because the
// uninstall path cannot depend on the library being loaded — the gateway
// sources it lazily, from inside its sweep functions, and an uninstall run from
// a bundle with no migrations/ never reaches that.
//
// So the drift is guarded rather than prevented, exactly as
// tools/prefix-gate-drift.test.sh guards the PREFIX gate's four copies. The
// region is delimited by the two sentinel comments the block itself carries,
// so a copy that is edited without moving the sentinels still fails.
//
// A FOURTH COPY EXISTS, and it is not checked here: the shared library's
// version sits INSIDE the SHARED SWEEP CONTRACT sentinels, so it travels to
// burrowee-git/gateway's copy of that library, where the pinned
// SWEEP_CONTRACT_DIGEST is what holds the two repos together.
package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	linkOwnershipBegin = "# --- LINK OWNERSHIP · BYTE-IDENTICAL COPY · do not edit one copy"
	linkOwnershipEnd   = "# --- end LINK OWNERSHIP"
)

// linkOwnershipBlock returns the delimited region of path, or fails.
func linkOwnershipBlock(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	s := string(b)
	i := strings.Index(s, linkOwnershipBegin)
	if i < 0 {
		t.Fatalf("%s carries no link-ownership block — the copy is gone, not merely drifted", path)
	}
	j := strings.Index(s[i:], linkOwnershipEnd)
	if j < 0 {
		t.Fatalf("%s: link-ownership block is not closed", path)
	}
	return s[i : i+j]
}

// TestLinkOwnershipCopiesAreIdentical — the guard the block's own header
// promises.
//
// Mutation that reddens it: change a word in any one copy.
func TestLinkOwnershipCopiesAreIdentical(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	paths := []string{
		filepath.Join(root, "_shared", "migrations", "lib_stale_user_bins.sh"),
		filepath.Join(root, "gateway", "install.sh"),
		filepath.Join(root, "edge", "install.sh"),
	}
	want := linkOwnershipBlock(t, paths[0])
	if !strings.Contains(want, "link_target_is_ours() {") {
		t.Fatalf("%s: the block does not define link_target_is_ours:\n%s", paths[0], want)
	}
	for _, p := range paths[1:] {
		if got := linkOwnershipBlock(t, p); got != want {
			t.Errorf("%s has drifted from %s.\nwant:\n%s\n\ngot:\n%s", p, paths[0], want, got)
		}
	}
}

// TestNoPrefixCompareSurvivesAnywhere — the shape the fix replaced, pinned as
// GONE. It is one line and it reads as harmless, which is exactly why it needs
// naming: `case "$(readlink …)" in "$BIN_DIR"/*)` accepts a target that walks
// back out of $BIN_DIR with "..".
//
// Mutation that reddens it: reintroduce the prefix compare at any of the three
// sites.
func TestNoPrefixCompareSurvivesAnywhere(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{
		filepath.Join(root, "_shared", "migrations", "lib_stale_user_bins.sh"),
		filepath.Join(root, "gateway", "install.sh"),
		filepath.Join(root, "edge", "install.sh"),
	} {
		b, readErr := os.ReadFile(p)
		if readErr != nil {
			t.Fatal(readErr)
		}
		for _, line := range strings.Split(string(b), "\n") {
			trimmed := strings.TrimSpace(line)
			// The block's own header quotes the old form to explain it; only
			// CODE counts.
			if strings.HasPrefix(trimmed, "#") {
				continue
			}
			if strings.Contains(line, `"$BIN_DIR"/*)`) {
				t.Errorf("%s still decides link ownership with a prefix compare: %s", p, trimmed)
			}
		}
	}
}
