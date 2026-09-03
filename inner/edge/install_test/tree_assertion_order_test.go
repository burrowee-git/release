// tree_assertion_order_test.go — the ordering rule for the system-tree
// assertions, asserted against the shipped installer text.
//
// THE RULE: a check that can REFUSE THE INSTALL runs before any step that
// TOUCHES THE HOST, and a check that needs no privilege does not sit behind a
// gate that does.
//
// It is here because it has been got wrong three times, and every time the
// cost fell on the operator rather than on the installer:
//
//   - the config-root symlink check used to run at the END of
//     assert_system_tree, after ensure_system_tree had already walked the tree
//     calling ensure_dir_stated — whose `chown 0:0` and `chmod` are spelled
//     without -h and so FOLLOW a symlink. An operator who pointed the config
//     root at a directory they owned had it taken to root:root 0755 and was
//     then told the install was refused and ownership was not the problem;
//   - it also sat below assert_system_tree's have_real_root gate, which exists
//     because OWNERSHIP needs uid 0 — irrelevant to an lstat. Where run_root
//     never reaches root and the modes already match, the assert returned 0
//     early and a symlinked config root was accepted in silence;
//   - and guarding inside ensure_dir_stated was still not enough, because the
//     levels are stated IN ORDER: a symlinked data root tripped the guard only
//     after the roots above it had been created and chowned, so the refusal's
//     own claim that nothing had been touched was false where it fired. One
//     list, walked twice — refuse every level, then create any of them.
//
// Asserted STRUCTURALLY, against the installer's own text, because the
// alternative is a fixture that must really chown a real directory to prove a
// real directory was not chowned. This is euid-independent and cannot go
// quietly vacuous.
package install_test

import (
	"os"
	"strings"
	"testing"
)

func TestTreeAssertionsRefuseBeforeTheyTouchTheHost(t *testing.T) {
	body := string(mustReadFile(t, installShPath(t)))
	for _, tc := range []struct {
		fn     string
		first  string
		second string
		why    string
	}{
		{
			fn:     "ensure_system_tree",
			first:  "assert_roots_not_symlinked",
			second: "ensure_dir_stated",
			why:    "the config root may not be a symlink whatever it points at, and that lstat needs no privilege and no host state — it decides the whole run, so nothing may be created before it",
		},
		{
			fn:     "ensure_system_tree",
			first:  "assert_level_safe_to_state",
			second: "ensure_dir_stated",
			why:    "chown and chmod state a symlinked level's TARGET — a directory outside this installer's tree — so EVERY level must be judged before the FIRST one is created, not each one just before itself",
		},
		{
			fn:     "assert_system_tree",
			first:  "assert_roots_not_symlinked",
			second: "have_real_root",
			why:    "the symlink check is a pure lstat and needs no privilege, so gating it on uid 0 lets a symlinked config root through on any run that never reaches root",
		},
	} {
		t.Run(tc.fn+"/"+tc.first, func(t *testing.T) {
			fnBody := shellFunctionBody(t, body, tc.fn)
			i := strings.Index(fnBody, tc.first)
			j := strings.Index(fnBody, tc.second)
			if i < 0 {
				t.Fatalf("%s() does not call %s at all", tc.fn, tc.first)
			}
			if j < 0 {
				t.Fatalf("%s() no longer mentions %s — this test is now checking the wrong thing", tc.fn, tc.second)
			}
			if i > j {
				t.Errorf("%s() reaches %s before %s — %s", tc.fn, tc.second, tc.first, tc.why)
			}
		})
	}
}

// TestLevelGuardJudgesTheChainAboveTheTargetNotTheTarget pins WHICH path the
// level guard judges, because the candidates differ by three characters and
// two of the three are wrong.
//
// $_alss_up is the RESOLVED parent of a symlinked level's target — the part
// ensure_dir_stated can never repair. The target itself is what it repairs on
// purpose: an operator who creates a directory, points a data root at it and
// runs the installer is meant to have it chowned to root, so judging the
// target would refuse that install. And "$_alss_d/.." is not the parent either
// — it resolves THROUGH the target before popping back to it, so it judges the
// target as well. dir_root_secure_test.go's
// TestDirIsRootSecureJudgesTheChainAboveASymlinkTargetSeparately shows all
// three verdicts and why only the resolved parent is usable.
func TestLevelGuardJudgesTheChainAboveTheTargetNotTheTarget(t *testing.T) {
	fn := shellFunctionBody(t, string(mustReadFile(t, installShPath(t))), "assert_level_safe_to_state")
	if !strings.Contains(fn, `dir_is_root_secure "$_alss_up"`) {
		t.Errorf("assert_level_safe_to_state does not judge $_alss_up — judging the target itself refuses an operator-created directory that this installer is meant to chown, judging \"$_alss_d/..\" judges the target too, and judging nothing lets chown and chmod follow the link into a tree that will be refused anyway")
	}
}

// TestSystemTreeLevelsIsTheOnlyLevelList — the two passes must walk the SAME
// list. A second copy beside the first is the drift this shape exists to
// prevent: a level added to the creating pass and forgotten in the refusing
// one is created before it is judged, which is the whole defect above.
func TestSystemTreeLevelsIsTheOnlyLevelList(t *testing.T) {
	body := string(mustReadFile(t, installShPath(t)))
	ensure := shellFunctionBody(t, body, "ensure_system_tree")
	if n := strings.Count(ensure, "ensure_dir_stated"); n != 1 {
		t.Errorf("ensure_system_tree names ensure_dir_stated %d times, want 1 — the levels belong to system_tree_levels, walked once per pass", n)
	}
	levels := shellFunctionBody(t, body, "system_tree_levels")
	if strings.Contains(levels, "ensure_dir_stated") {
		t.Errorf("system_tree_levels names ensure_dir_stated directly — it must call whatever it is handed, so the same list serves both passes")
	}
	if n := strings.Count(levels, `"$1" `); n < 8 {
		t.Errorf("system_tree_levels dispatches %d levels, want at least 8 — has a level been inlined back into a caller?", n)
	}
}

// shellFunctionBody returns one shell function's text, brace to brace.
func shellFunctionBody(t *testing.T, body, name string) string {
	t.Helper()
	open := "\n" + name + "() {\n"
	b := strings.Index(body, open)
	if b < 0 {
		t.Fatalf("the installer defines no %s()", name)
	}
	rest := body[b+len(open):]
	e := strings.Index(rest, "\n}\n")
	if e < 0 {
		t.Fatalf("%s() is never closed", name)
	}
	return rest[:e]
}

// mustReadFile is this package's minimal file read; the gateway package has
// mustRead already and this one does not.
func mustReadFile(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return b
}
