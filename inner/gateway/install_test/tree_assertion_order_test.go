// tree_assertion_order_test.go — the ordering rule for the system-tree
// assertions, asserted against the shipped installer text.
//
// THE RULE: a check that can REFUSE THE INSTALL runs before any step that
// TOUCHES THE HOST, and a check that needs no privilege does not sit behind a
// gate that does.
//
// It is here because it was got wrong twice in one function, and both times
// the cost fell on the operator rather than on the installer:
//
//   - assert_roots_not_symlinked used to run at the END of assert_system_tree,
//     which is after ensure_system_tree has walked the tree calling
//     ensure_dir_stated — and ensure_dir_stated does `run_root chown 0:0` and
//     `run_root chmod 0755`, NEITHER with -h, so both FOLLOW a symlink. An
//     operator who pointed the config root at a directory they owned had that
//     directory taken to root:root 0755 and was then told the install was
//     refused and that ownership was not the problem. The refusal was certain
//     from the moment the link was seen, so the mutation bought nothing.
//   - and it sat below assert_system_tree's have_real_root gate, which exists
//     because OWNERSHIP needs uid 0 — irrelevant to an lstat. Where run_root
//     never reaches root and the modes already match, the assert returned 0
//     early and a symlinked config root was accepted in silence.
//
// Asserted STRUCTURALLY, against the installer's own text, because the
// alternative is a fixture that must really chown a real directory to prove a
// real directory was not chowned. This is euid-independent and cannot go
// quietly vacuous.
//
// Mutations that redden it: move `assert_roots_not_symlinked` below the first
// ensure_dir_stated in ensure_system_tree, or below the `have_real_root` gate
// in assert_system_tree.
package install_test

import (
	"strings"
	"testing"
)

func TestTreeAssertionsRefuseBeforeTheyTouchTheHost(t *testing.T) {
	body := string(mustRead(t, installShPath(t)))
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
			why:    "ensure_dir_stated chowns and chmods THROUGH a symlink (no -h), so a refusal that comes after it has already changed a directory the operator owns",
		},
		{
			fn:    "ensure_dir_stated",
			first: "dir_leaf_is_symlink",
			// `mkdir` is the first thing here that changes the host, and it
			// is spelled the same in both installers (gateway wraps it in
			// run_root; edge already runs as root), so it is the marker that
			// works for both without either test knowing the other's shape.
			second: "mkdir",
			why:    "chown and chmod here are spelled without -h, so they state the link's TARGET — a directory outside this installer's tree — and a level whose target chain will be refused anyway must be refused before the first write, not after it",
		},
		{
			fn:     "assert_system_tree",
			first:  "assert_roots_not_symlinked",
			second: "have_real_root",
			why:    "the symlink check is a pure lstat and needs no privilege, so gating it on uid 0 lets a symlinked config root through on any run that never reaches root",
		},
	} {
		t.Run(tc.fn, func(t *testing.T) {
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

// shellFunctionBody returns one shell function's text, brace to brace.
// TestEnsureDirStatedJudgesTheChainAboveTheTargetNotTheTarget pins WHICH path
// the guard judges, because the two differ by three characters and the wrong
// one refuses a supported layout.
//
// $_eds_up is the RESOLVED parent of a symlinked level's target — the part
// ensure_dir_stated can never repair. The target itself is what it repairs on
// purpose: an operator who creates a directory, points a data root
// at it and runs the installer is meant to have it chowned to root. Judging
// the target would refuse that install.
// dir_root_secure_test.go's TestDirIsRootSecureJudgesTheChainAboveASymlinkTargetSeparately
// shows the two verdicts genuinely disagree in exactly that case.
func TestEnsureDirStatedJudgesTheChainAboveTheTargetNotTheTarget(t *testing.T) {
	fn := shellFunctionBody(t, string(mustRead(t, installShPath(t))), "ensure_dir_stated")
	if !strings.Contains(fn, `dir_is_root_secure "$_eds_up"`) {
		t.Errorf("ensure_dir_stated does not judge $_eds_up — judging the target itself refuses an operator-created directory that this installer is meant to chown, and judging nothing lets chown and chmod follow the link into a tree that will be refused anyway")
	}
}

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
