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
	"os/exec"
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

// linkOwnershipPaths is the three files that carry a copy of the block.
func linkOwnershipPaths(t *testing.T) []string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return []string{
		filepath.Join(root, "_shared", "migrations", "lib_stale_user_bins.sh"),
		filepath.Join(root, "gateway", "install.sh"),
		filepath.Join(root, "edge", "install.sh"),
	}
}

// TestEveryReadlinkRoutesThroughLinkOwnership — there is ONE place that reads a
// symlink to decide whose it is, and it is the block.
//
// THIS REPLACED A GUARD THAT DID NOT GUARD. It used to grep for the literal
// string `"$BIN_DIR"/*)`, which is one spelling of the old prefix compare and
// not the construct: `case "$(readlink "$p")" in "$BIN_DIR/"*)` — the same bug
// with the slash inside the quotes — sailed straight past it. A check named
// "no prefix compare survives anywhere" that passes while a prefix compare
// survives is worse than no check at all, because the next reader trusts it.
//
// The claim is now positive and spelling-independent: every occurrence of
// `readlink` in these files, outside comments, must lie inside the block. A
// second site cannot decide link ownership without reading the link, so it
// cannot be added without failing this — however it spells its pattern, and
// whether it uses `case`, `test`, or a parameter expansion.
//
// WHAT THIS DOES NOT COVER, said out loud: it says nothing about what the
// block itself does. Three things together do.
//
//	1. TestEveryCopyOfLinkOwnershipRefusesAnEscapingTarget (below) drives the
//	   extracted block from all three files against every target shape.
//	2. TestLinkOwnershipCopiesAreIdentical proves those three are one text.
//	3. TestEdgeInstallSparesALinkEscapingBinDirWithDotDot proves the library's
//	   copy is actually WIRED IN — a correct function nothing calls is not a
//	   guard either.
//
// Mutation that reddens it: put a readlink-based compare back at any decision
// site, in any spelling.
func TestEveryReadlinkRoutesThroughLinkOwnership(t *testing.T) {
	for _, p := range linkOwnershipPaths(t) {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		block := linkOwnershipBlock(t, p)
		for n, line := range strings.Split(string(b), "\n") {
			// The block's own header quotes the old form to explain it, and so
			// do other comments; only CODE counts.
			if strings.HasPrefix(strings.TrimSpace(line), "#") {
				continue
			}
			if !strings.Contains(line, "readlink") {
				continue
			}
			if !strings.Contains(block, line) {
				t.Errorf("%s:%d decides link ownership outside the link-ownership block: %s",
					p, n+1, strings.TrimSpace(line))
			}
		}
	}
}

// escapingTargetCase is one symlink shape and the verdict every copy owes it.
type escapingTargetCase struct {
	name   string
	target func(binDir, home string) string
	ours   bool
	why    string
}

// TestEveryCopyOfLinkOwnershipRefusesAnEscapingTarget — the CONSTRUCT, driven
// against all three copies rather than inferred from one.
//
// The block is extracted by its own sentinels and sourced on its own, which is
// what makes this possible for the two installers: neither can be run to reach
// unlink_operator_bins without performing an install, and only the gateway has
// a BURROWEE_SOURCE_ONLY seam. Extraction is honest here precisely because
// TestLinkOwnershipCopiesAreIdentical pins the extracted text to the file it
// came from.
//
// Mutation that reddens it: any prefix compare, in any spelling, in any copy.
func TestEveryCopyOfLinkOwnershipRefusesAnEscapingTarget(t *testing.T) {
	cases := []escapingTargetCase{
		{
			name:   "ours",
			target: func(binDir, _ string) string { return filepath.Join(binDir, "burrowee") },
			ours:   true,
			why:    "a clean absolute target directly inside $BIN_DIR is exactly what the installers wrote",
		},
		{
			name:   "escapes-with-dotdot",
			target: func(binDir, home string) string { return binDir + "/../outside/wrapper" },
			ours:   false,
			why:    "it begins with $BIN_DIR/ and resolves outside it — the whole bug",
		},
		{
			name:   "dot-component",
			target: func(binDir, _ string) string { return binDir + "/./burrowee" },
			ours:   false,
			why:    "refused rather than folded: no install ever wrote it",
		},
		{
			name:   "doubled-slash",
			target: func(binDir, _ string) string { return binDir + "//burrowee" },
			ours:   false,
			why:    "same argument as the dot component",
		},
		{
			name:   "trailing-slash",
			target: func(binDir, _ string) string { return filepath.Join(binDir, "burrowee") + "/" },
			ours:   false,
			why:    "names a directory, not a file this installer placed",
		},
		{
			name:   "relative",
			target: func(_, _ string) string { return "burrowee" },
			ours:   false,
			why:    "every link this project made was absolute",
		},
		{
			name:   "one-level-deeper",
			target: func(binDir, _ string) string { return filepath.Join(binDir, "sub", "burrowee") },
			ours:   false,
			why:    "the directory must be $BIN_DIR exactly, not a prefix of the target",
		},
		{
			name:   "sibling-directory",
			target: func(binDir, _ string) string { return binDir + "-old/burrowee" },
			ours:   false,
			why:    "never a hole in the prefix form either, but now it is the RULE that says so",
		},
		{
			name:   "bin-dir-itself",
			target: func(binDir, _ string) string { return binDir },
			ours:   false,
			why:    "$BIN_DIR names no file",
		},
	}

	for _, p := range linkOwnershipPaths(t) {
		t.Run(filepath.Base(filepath.Dir(p))+"/"+filepath.Base(p), func(t *testing.T) {
			script := filepath.Join(t.TempDir(), "block.sh")
			if err := os.WriteFile(script, []byte(linkOwnershipBlock(t, p)), 0o644); err != nil {
				t.Fatal(err)
			}
			for _, tc := range cases {
				t.Run(tc.name, func(t *testing.T) {
					home := t.TempDir()
					binDir := filepath.Join(home, "bin")
					if err := os.MkdirAll(binDir, 0o755); err != nil {
						t.Fatal(err)
					}
					link := filepath.Join(home, "legacy-burrowee")
					if err := os.Symlink(tc.target(binDir, home), link); err != nil {
						t.Fatal(err)
					}
					cmd := exec.Command("sh", "-c",
						`. "$1"; if link_target_is_ours "$2"; then echo ours; else echo foreign; fi`,
						"sh", script, link)
					cmd.Env = []string{"PATH=/usr/bin:/bin", "BIN_DIR=" + binDir}
					out, err := cmd.CombinedOutput()
					if err != nil {
						t.Fatalf("driving the block failed: %v\n%s", err, out)
					}
					got := strings.TrimSpace(string(out))
					want := "foreign"
					if tc.ours {
						want = "ours"
					}
					if got != want {
						t.Errorf("target %q → %s, want %s (%s)", tc.target(binDir, home), got, want, tc.why)
					}
				})
			}
		})
	}
}
