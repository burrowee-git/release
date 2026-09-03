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
