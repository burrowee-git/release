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
	"path/filepath"
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
	fn := shellFunctionBody(t, string(mustRead(t, installShPath(t))), "assert_level_safe_to_state")
	if !strings.Contains(fn, `dir_is_root_secure "$_alss_up"`) {
		t.Errorf("assert_level_safe_to_state does not judge $_alss_up — judging the target itself refuses an operator-created directory that this installer is meant to chown, judging \"$_alss_d/..\" judges the target too, and judging nothing lets chown and chmod follow the link into a tree that will be refused anyway")
	}
}

// TestSystemTreeLevelsIsTheOnlyLevelList — the two passes must walk the SAME
// list. A second copy beside the first is the drift this shape exists to
// prevent: a level added to the creating pass and forgotten in the refusing
// one is created before it is judged, which is the whole defect above.
func TestSystemTreeLevelsIsTheOnlyLevelList(t *testing.T) {
	body := string(mustRead(t, installShPath(t)))
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

// TestNoPathJudgingFunctionEntersTheDirectory is the no-`cd` rule, applied to
// EVERY function this installer defines rather than to the pinned region.
//
// THE POINT IS THE SCOPE. There was already a test forbidding a `cd` in the
// functions that judge a path — and it scanned the contract region only. A
// helper added OUTSIDE the region then resolved a parent with
// `cd -P -- "$dir/.."`, which needs SEARCH permission on the symlink's target,
// and the installer states data roots to root:root 0700 through exactly such
// links: the layout installed once and refused every re-run afterwards. The
// guard could not see it by construction, because the guard covered a REGION
// and the rule is about a BEHAVIOUR.
//
// So the rule is now: any function that consults the root-secure predicates is
// judging a path, and a function that judges a path does not enter it. `[ -d ]`,
// `[ -L ]`, `readlink`, `dirname` and `stat` need search on a path's PARENT;
// `cd` needs it on the path itself, and the account this installer runs as is
// exactly the account that does not have it.
//
// Mutation that reddens it: resolve the parent in assert_level_safe_to_state
// with `cd -P -- "$_alss_d/.."` again.
func TestNoPathJudgingFunctionEntersTheDirectory(t *testing.T) {
	predicates := []string{
		"dir_is_root_secure", "dir_level_is_root_secure", "dir_probe_reason",
		"dir_spelling_normalize", "dir_leaf_is_symlink", "dir_leaf_is_notdir",
	}
	body := string(mustRead(t, installShPath(t)))
	fns := shellFunctionNames(body)
	if len(fns) < 20 {
		t.Fatalf("only %d functions found in the installer — the scanner is not seeing the file", len(fns))
	}
	judging := 0
	for _, name := range fns {
		code := stripShellComments(shellFunctionBody(t, body, name))
		judges := false
		for _, pred := range predicates {
			// A predicate's own definition does not count as consulting it.
			if strings.Contains(code, pred) && name != pred {
				judges = true
			}
		}
		if !judges {
			continue
		}
		judging++
		for i, line := range strings.Split(code, "\n") {
			if strings.Contains(line, "cd ") {
				t.Errorf("%s() judges a path and changes directory (line %d): %s\n"+
					"a `cd` needs search permission on the path itself; every other probe needs it only on the parent, and this installer runs as an account that has neither on a root-owned 0700 tree",
					name, i+1, strings.TrimSpace(line))
			}
		}
	}
	if judging < 3 {
		t.Errorf("only %d functions were found to consult the predicates — expected at least 3, so this test is probably matching nothing", judging)
	}
}

// TestOutOfPinNamesExist keeps the region's "THE PIN IS NOT THE WHOLE CONTRACT"
// list honest. It is the instruction another repo follows when it re-syncs the
// pinned region, and it went stale within one round of being written: it named
// a guard inside ensure_dir_stated that had already been replaced, so a repo
// following it would have looked there, found nothing, and shipped the region
// with chown and chmod still following a symlink out of its own tree.
func TestOutOfPinNamesExist(t *testing.T) {
	body := string(mustRead(t, installShPath(t)))
	const head = "# THE PIN IS NOT THE WHOLE CONTRACT."
	const tail = "# They are outside deliberately"
	b := strings.Index(body, head)
	e := strings.Index(body, tail)
	if b < 0 || e < b {
		t.Fatal("the out-of-pin block is missing or its bounds moved — this test can no longer find the list it checks")
	}
	sweep := filepath.Join(filepath.Dir(filepath.Dir(installShPath(t))), "_shared", "migrations", "lib_stale_user_bins.sh")
	lib, err := os.ReadFile(sweep)
	if err != nil {
		t.Fatalf("read %s: %v", sweep, err)
	}
	var named []string
	for _, line := range strings.Split(body[b:e], "\n") {
		if !strings.HasPrefix(line, "#   * ") {
			continue
		}
		name := strings.Fields(strings.TrimPrefix(line, "#   * "))[0]
		named = append(named, name)
		if !strings.Contains(body, "\n"+name+"() {\n") && !strings.Contains(string(lib), "\n"+name+"() {\n") {
			t.Errorf("the out-of-pin list names %s, which no longer exists in the installer or the sweep library — a repo re-syncing the region would look for it and find nothing", name)
		}
	}
	if len(named) < 4 {
		t.Errorf("the out-of-pin list names %d functions, want at least 4 — has the list lost entries, or the marker changed?", len(named))
	}
}

// shellFunctionNames returns every `name() {` this file defines, in order.
func shellFunctionNames(body string) []string {
	var out []string
	for _, line := range strings.Split(body, "\n") {
		if !strings.HasSuffix(line, "() {") || strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t") {
			continue
		}
		out = append(out, strings.TrimSuffix(line, "() {"))
	}
	return out
}

// stripShellComments drops whole-line comments so prose about `cd` is not read
// as a call to it.
func stripShellComments(body string) string {
	var kept []string
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			kept = append(kept, "")
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n")
}

// TestNormalizingFunctionsDoNotReadTheRawSpelling is the raw-spelling rule,
// made structural because remembering it has now failed three times.
//
// dir_spelling_normalize exists so that every spelling of one directory gets
// one answer. A function that normalizes and then reads $1 again for something
// else silently disagrees with the predicates it just called: the level guard
// normalized through dir_leaf_is_symlink and then ran `readlink` and `dirname`
// on the raw argument, so a level spelled `X/` or `X/.` made readlink fail
// EINVAL and refused an install the bare spelling accepts, while
// `dirname "X/."` answered the link itself rather than its directory.
//
// So: a function that normalizes uses $1 EXACTLY ONCE — to normalize it.
// Everything after that reads the normalized value. That is one assignment at
// the top of a function instead of a rule every new site has to know.
//
// Mutation that reddens it: read "$1" instead of "$_alss_d" anywhere in
// assert_level_safe_to_state after the normalize call.
func TestNormalizingFunctionsDoNotReadTheRawSpelling(t *testing.T) {
	body := string(mustRead(t, installShPath(t)))
	checked := 0
	for _, name := range shellFunctionNames(body) {
		code := stripShellComments(shellFunctionBody(t, body, name))
		if !strings.Contains(code, "dir_spelling_normalize") {
			continue
		}
		checked++
		if n := strings.Count(code, "$1"); n != 1 {
			t.Errorf("%s() normalizes its argument but reads $1 %d times, want exactly 1 — every read after the normalize call must use the normalized value, or this function disagrees with the predicates it just called about which directory $1 names",
				name, n)
		}
	}
	if checked < 3 {
		t.Errorf("only %d normalizing functions were found — expected at least 3, so this test is probably matching nothing", checked)
	}
}
