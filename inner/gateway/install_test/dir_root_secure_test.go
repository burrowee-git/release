// dir_root_secure_test.go — dir_is_root_secure, the DIRECTORY form of the
// root-secure predicate, driven in isolation against a stat of known answers.
//
// path_is_root_secure gates a root EXEC (bin_dir_elevation_test.go,
// stat_portability_test.go). dir_is_root_secure gates where root's STATE is
// about to be created — the machine-owned tree the 0.3 installer builds and
// then asserts. The two share an ancestor walk and differ only in the leaf,
// and this file proves the leaf half and the walk answer BOTH ways: a tree that
// passes and a tree that refuses, with every one of the four return codes
// reachable.
//
// The stat on PATH is a stub that answers from two lookup tables, so the
// fixture is independent of who runs this suite: a real 0775 directory made by
// an unprivileged test user would ALSO fail the uid test, and the mode
// assertion would then be passing for the wrong reason.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// rootSecureContractRegion extracts the ROOT-SECURE CONTRACT region from
// install.sh — sentinel to sentinel — so the predicate under test is the
// shipped text, not a transcription of it. Checked rather than trusted:
// a moved or renamed function fails loudly here instead of leaving a probe
// that evaluates the wrong text.
func rootSecureContractRegion(t *testing.T) string {
	t.Helper()
	body := string(mustRead(t, installShPath(t)))
	const begin = "# === ROOT-SECURE CONTRACT BEGIN ===\n"
	const end = "# === ROOT-SECURE CONTRACT END ===\n"
	b := strings.Index(body, begin)
	if b < 0 {
		t.Fatalf("install.sh carries no %q sentinel", strings.TrimSpace(begin))
	}
	e := strings.Index(body[b:], end)
	if e < 0 {
		t.Fatalf("install.sh carries no %q sentinel", strings.TrimSpace(end))
	}
	region := body[b : b+e+len(end)]
	for _, want := range []string{"dir_is_root_secure() {", "path_is_root_secure() {", "mode_allows_nonroot_write() {"} {
		if !strings.Contains(region, want) {
			t.Fatalf("the extracted contract region lacks %q — the sentinels fence the wrong text", want)
		}
	}
	return region
}

// statStubTable is a GNU-dialect stat that answers `-c '%u'` and `-c '%a'`
// from two files: $STAT_UIDS and $STAT_MODES, each "path value" per line.
// A path listed in neither answers uid 0 / mode 755 — a correctly-installed
// root-owned tree — so a fixture states only the deviation it is about.
// `-f` fails the way BSD stat's probe expects a foreign flag to, so the
// dialect probe resolves to gnu.
const statStubTable = `#!/bin/sh
[ "${1:-}" = "-c" ] || { echo "stat: unrecognized option" >&2; exit 1; }
_fmt="$2"; _p="$3"
[ -e "$_p" ] || { echo "stat: cannot statx '$_p': No such file or directory" >&2; exit 1; }
_lookup() {
    _v=""
    [ -f "$1" ] && _v="$(awk -v p="$2" '$1 == p { print $2 }' "$1")"
    [ -n "$_v" ] || _v="$3"
    printf '%s\n' "$_v"
}
case "$_fmt" in
'%u') _lookup "${STAT_UIDS:-/nonexistent}" "$_p" 0 ;;
'%a') _lookup "${STAT_MODES:-/nonexistent}" "$_p" 755 ;;
*) echo "stat: invalid directive" >&2; exit 1 ;;
esac
`

// dirIsRootSecure runs dir_is_root_secure on target with the stat stub's
// tables set as given, returning the predicate's exit code.
func dirIsRootSecure(t *testing.T, target string, uids, modes map[string]string) int {
	t.Helper()
	stub := t.TempDir()
	if err := os.WriteFile(filepath.Join(stub, "stat"), []byte(statStubTable), 0o755); err != nil {
		t.Fatal(err)
	}
	table := func(name string, m map[string]string) string {
		p := filepath.Join(stub, name)
		var sb strings.Builder
		for k, v := range m {
			sb.WriteString(k + " " + v + "\n")
		}
		if err := os.WriteFile(p, []byte(sb.String()), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	probe := rootSecureContractRegion(t) + "\ndir_is_root_secure " + shQuote(target) + "\nexit $?\n"
	cmd := exec.Command("sh", "-c", probe)
	cmd.Env = []string{
		"PATH=" + stub + ":/usr/bin:/bin",
		"STAT_UIDS=" + table("uids", uids),
		"STAT_MODES=" + table("modes", modes),
	}
	out, err := cmd.CombinedOutput()
	if err == nil {
		return 0
	}
	if ee, ok := err.(*exec.ExitError); ok {
		return ee.ExitCode()
	}
	t.Fatalf("probe did not run: %v\n%s", err, out)
	return -1
}

// TestDirIsRootSecureAnswersEveryCodeBothWays drives the four return codes.
//
// Mutations that redden it, by case:
//   - "leaf 0775" and "leaf 0735": drop 2|3 or 6|7 from
//     mode_allows_nonroot_write's group case (0735's group digit is 3 — write
//     without read — and is what catches a case narrowed to 6|7);
//   - "ancestor 0775": delete the ancestor walk and check the leaf alone;
//   - "leaf not root-owned": drop the uid test;
//   - "unreadable": return 1 instead of 2 when stat does not answer;
//   - "absent": return 1 instead of 3 for a missing directory.
func TestDirIsRootSecureAnswersEveryCodeBothWays(t *testing.T) {
	root := t.TempDir()
	parent := filepath.Join(root, "burrowee")
	leaf := filepath.Join(parent, "var")
	if err := os.MkdirAll(leaf, 0o755); err != nil {
		t.Fatal(err)
	}
	none := map[string]string{}
	cases := []struct {
		name   string
		target string
		uids   map[string]string
		modes  map[string]string
		want   int
	}{
		{"leaf 0755 under root-owned 0755 ancestors", leaf, none, none, 0},
		{"leaf 0700 is still root-secure", leaf, none, map[string]string{leaf: "700"}, 0},
		{"leaf 0775 is group-writable", leaf, none, map[string]string{leaf: "775"}, 1},
		{"leaf 0735 carries the group write bit without read", leaf, none, map[string]string{leaf: "735"}, 1},
		{"leaf 0757 is world-writable", leaf, none, map[string]string{leaf: "757"}, 1},
		{"ancestor 0775 above a 0755 leaf", leaf, none, map[string]string{parent: "775"}, 1},
		{"leaf not root-owned", leaf, map[string]string{leaf: "501"}, none, 1},
		{"ancestor not root-owned", leaf, map[string]string{parent: "501"}, none, 1},
		{"absent directory", filepath.Join(parent, "missing"), none, none, 3},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := dirIsRootSecure(t, tc.target, tc.uids, tc.modes); got != tc.want {
				t.Errorf("dir_is_root_secure(%s) = %d, want %d", tc.target, got, tc.want)
			}
		})
	}
}

// TestDirIsRootSecureReportsUndecidableNotInsecure is code 2: a stat that
// does not answer must not be read as "not root-owned" — that message sends
// an operator to audit permissions that were never the problem, which is
// exactly what the dialect bug cost once already.
func TestDirIsRootSecureReportsUndecidableNotInsecure(t *testing.T) {
	leaf := filepath.Join(t.TempDir(), "burrowee")
	if err := os.MkdirAll(leaf, 0o755); err != nil {
		t.Fatal(err)
	}
	stub := t.TempDir()
	// A stat that resolves the dialect probe on "/" and then answers junk for
	// everything else — the shape stat_portability_test.go's statStubJunk has.
	junk := "#!/bin/sh\n_last=\"\"; for _a in \"$@\"; do _last=\"$_a\"; done\n" +
		"if [ \"$_last\" = / ]; then echo 0; exit 0; fi\necho junk; exit 0\n"
	if err := os.WriteFile(filepath.Join(stub, "stat"), []byte(junk), 0o755); err != nil {
		t.Fatal(err)
	}
	probe := rootSecureContractRegion(t) + "\ndir_is_root_secure " + shQuote(leaf) + "\nexit $?\n"
	cmd := exec.Command("sh", "-c", probe)
	cmd.Env = []string{"PATH=" + stub + ":/usr/bin:/bin"}
	out, err := cmd.CombinedOutput()
	ee, ok := err.(*exec.ExitError)
	if !ok {
		t.Fatalf("want exit 2 (undecidable), got err=%v\n%s", err, out)
	}
	if ee.ExitCode() != 2 {
		t.Errorf("dir_is_root_secure with an unreadable stat = %d, want 2 (undecidable, not insecure)\n%s", ee.ExitCode(), out)
	}
}

// TestDirIsRootSecureJudgesTheChainThatHoldsASymlinkedLeaf — a symlinked leaf
// has TWO ancestor chains and both decide. Walking only the target's ignores
// the directory that holds the link: with a group-writable /usr/local and
// /usr/local/bin -> a root-owned tree, the target walks clean while the owner
// of /usr/local can repoint `bin` whenever they like, after which every root
// symlink this installer made addresses their directory instead.
//
// Mutation that reddens it: drop the `dir_chain_is_root_secure "$_ds_p"` call
// from the `[ -L ]` branch, so only the resolved target is walked.
func TestDirIsRootSecureJudgesTheChainThatHoldsASymlinkedLeaf(t *testing.T) {
	root := t.TempDir()
	holder := filepath.Join(root, "holder")
	target := filepath.Join(root, "target", "bin")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(holder, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(holder, "bin")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	none := map[string]string{}

	// Both chains sound: secure.
	if rc := dirIsRootSecure(t, link, none, none); rc != 0 {
		t.Errorf("a symlinked leaf with both chains root-owned: rc = %d, want 0", rc)
	}
	// The HOLDER is group-writable while the target is spotless — the case the
	// resolution alone cannot see.
	if rc := dirIsRootSecure(t, link, none, map[string]string{holder: "775"}); rc != 1 {
		t.Errorf("a group-writable directory holding the link: rc = %d, want 1 — its owner can repoint the link", rc)
	}
	// And the mirror image: holder sound, target group-writable.
	if rc := dirIsRootSecure(t, link, none, map[string]string{target: "775"}); rc != 1 {
		t.Errorf("a group-writable symlink target: rc = %d, want 1", rc)
	}
	// A holder owned by someone other than root is refused on uid, not mode.
	if rc := dirIsRootSecure(t, link, map[string]string{holder: "501"}, none); rc != 1 {
		t.Errorf("a non-root-owned directory holding the link: rc = %d, want 1", rc)
	}
}
