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
	"strconv"
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
	return dirIsRootSecureFrom(t, "", target, uids, modes)
}

// dirIsRootSecureFrom is dirIsRootSecure with the probe's working directory
// chosen. A relative target is judged against the PHYSICAL working directory
// and that directory's own components are part of the answer, so the cwd is an
// input to the predicate and needs a seam like any other input.
func dirIsRootSecureFrom(t *testing.T, cwd, target string, uids, modes map[string]string) int {
	t.Helper()
	return rootSecureProbe(t, cwd, "dir_is_root_secure "+shQuote(target), uids, modes)
}

// dirLeafIsSymlink runs the region's dir_leaf_is_symlink — the caller-facing
// rule, and the ONLY thing that refuses a symlinked leaf anywhere. The
// predicate itself follows one; assert_system_tree asks this about the CONFIG
// root alone, mirroring the single place Go wires IsRootSecureDir. So this
// function is what has to be right for every spelling: it is the whole
// refusal, not a hint about one.
func dirLeafIsSymlink(t *testing.T, target string) bool {
	t.Helper()
	none := map[string]string{}
	return rootSecureProbe(t, "", "dir_leaf_is_symlink "+shQuote(target), none, none) == 0
}

// dirLeafIsNotdir runs the region's dir_leaf_is_notdir.
func dirLeafIsNotdir(t *testing.T, target string) bool {
	t.Helper()
	none := map[string]string{}
	return rootSecureProbe(t, "", "dir_leaf_is_notdir "+shQuote(target), none, none) == 0
}

// rootSecureProbe runs one shell call against the shipped contract region with
// the stat stub's tables set as given, from working directory cwd ("" inherits
// the test process's), and returns its exit code.
func rootSecureProbe(t *testing.T, cwd, call string, uids, modes map[string]string) int {
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
	probe := rootSecureContractRegion(t) + "\n" + call + "\nexit $?\n"
	cmd := exec.Command("sh", "-c", probe)
	cmd.Dir = cwd
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
//   - "ancestor 0775": delete the ancestor walk and check the leaf alone, or
//     delete the `|| return $?` from the walk's dir_level_is_root_secure call;
//   - "leaf not root-owned": drop the uid test;
//   - "unreadable": return 1 instead of 2 when stat does not answer;
//   - "absent": return 1 instead of 3 for a missing directory.
func TestDirIsRootSecureAnswersEveryCodeBothWays(t *testing.T) {
	root := canonicalTempDir(t)
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
	leaf := filepath.Join(canonicalTempDir(t), "burrowee")
	if err := os.MkdirAll(leaf, 0o755); err != nil {
		t.Fatal(err)
	}
	stub := t.TempDir()
	// A stat that answers for "/" — the dialect probe's subject, and the first
	// component of every walk — and junk for everything below it, which is the
	// shape stat_portability_test.go's statStubJunk has. Answering "/" with a
	// bare 0 would mean a MODE of "0": a one-character mode is "assume the
	// worst" by design, so the walk would refuse at / with code 1 and this
	// test would pass while proving nothing about an unreadable stat.
	junk := "#!/bin/sh\n_last=\"\"; for _a in \"$@\"; do _last=\"$_a\"; done\n" +
		"if [ \"$_last\" = / ]; then case \"${2:-}\" in '%u') echo 0 ;; *) echo 755 ;; esac; exit 0; fi\n" +
		"echo junk; exit 0\n"
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
// has TWO ancestor chains and both decide. The predicate FOLLOWS it: refusing
// one outright is a rule that belongs to a single caller, not to this
// predicate, and the scope is an operator ruling recorded in the region header
// — a symlinked $SYS_DATA_DIR or $SYSTEM_ROOT is the ordinary "put var on the
// big disk" layout, it installed cleanly before this branch and the daemon
// never rejects it, so a hard refusal here would have broken a supported
// layout. Only the CONFIG root's caller refuses, mirroring the one place Go
// wires IsRootSecureDir.
//
// What protects every root, including the config root, is this: both chains
// are judged, so the directory that HOLDS the link is judged as well as the
// tree it points into.
//
// Mutations that redden it: delete the `[ -L "$_ds_cur" ]` branch, so the link
// is judged by its own uid and mode instead of being followed; or delete the
// `|| return $?` from the walk's dir_level_is_root_secure call.
func TestDirIsRootSecureJudgesTheChainThatHoldsASymlinkedLeaf(t *testing.T) {
	root := canonicalTempDir(t)
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

	if rc := dirIsRootSecure(t, link, none, none); rc != 0 {
		t.Errorf("a symlinked leaf with both chains root-owned: rc = %d, want 0 — this predicate follows it; the config root's own refusal is the caller's", rc)
	}
	if rc := dirIsRootSecure(t, link, none, map[string]string{holder: "775"}); rc != 1 {
		t.Errorf("a group-writable directory holding the link: rc = %d, want 1 — its owner can repoint the link", rc)
	}
	if rc := dirIsRootSecure(t, link, none, map[string]string{target: "775"}); rc != 1 {
		t.Errorf("a group-writable symlink target: rc = %d, want 1", rc)
	}
	if rc := dirIsRootSecure(t, link, map[string]string{holder: "501"}, none); rc != 1 {
		t.Errorf("a non-root-owned directory holding the link: rc = %d, want 1", rc)
	}
}

// TestDirLeafIsSymlinkAnswersEverySpelling is the caller-facing half of the
// rule, and the spellings ARE the test.
//
// dir_leaf_is_symlink is what assert_system_tree asks about the CONFIG root
// alone. A rule a caller can step around by adding one character is not a
// rule, and the first form of this one stripped only trailing slashes:
// `…/link/.` walked straight past it. $BIN_DIR, the $SYS_* roots and $LINK_DIR
// all arrive from operator environment, so every spelling below is reachable.
// The negative half matters as much: a rule that swallowed `X/..` or an
// interior `.` would refuse real directories.
//
// Mutations that redden it:
//   - delete the `*/) … %/}` arm of dir_spelling_normalize: the trailing
//     separator spellings;
//   - delete its `*/.) … %/.}` arm: the /. spellings — the exact regression;
//   - delete the `dir_spelling_normalize` call: all of them but the first.
func TestDirLeafIsSymlinkAnswersEverySpelling(t *testing.T) {
	root := canonicalTempDir(t)
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
	dangling := filepath.Join(holder, "gone")
	if err := os.Symlink(filepath.Join(root, "no-such-tree"), dangling); err != nil {
		t.Fatal(err)
	}
	for _, spelling := range []string{
		link,             // as spelled
		link + "/",       // trailing separator
		link + "//",      // doubled separator
		link + "/.",      // the spelling that walked through the first form
		link + "/./",     // and with a separator after it
		link + "/.//.",   // and interleaved
		holder + "//bin", // a doubled separator above the leaf
		dangling,         // a link whose target does not exist is still a link
	} {
		if !dirLeafIsSymlink(t, spelling) {
			t.Errorf("dir_leaf_is_symlink(%q) = false, want true — one character must not step around the rule", spelling)
		}
	}
	for _, tc := range []struct{ spelling, why string }{
		{link + "/..", "/.. names the target's PARENT, a real directory — .. from anywhere yields one"},
		{target, "a real leaf"},
		{filepath.Join(root, "target") + "/./bin", "an interior . does not touch the leaf"},
		{filepath.Join(root, "target") + "//bin", "an interior // does not touch the leaf"},
		{root, "a plain directory"},
		{"/", "the root directory"},
		{"/.", "the root, spelled with a dot — the normalizer empties this one and must put / back"},
		{"/./", "the same, with a separator"},
		{"", "an empty operand names nothing at all"},
	} {
		if dirLeafIsSymlink(t, tc.spelling) {
			t.Errorf("dir_leaf_is_symlink(%q) = true, want false — %s", tc.spelling, tc.why)
		}
	}
}

// TestDirIsRootSecureSeparatesAbsentFromUnresolvable is the other half of the
// 3-vs-2 boundary, and the half that needs no euid: 3 says "there is no
// directory here", 2 says "I could not establish anything". Confusing them
// sends an operator to the wrong place in BOTH directions, and both directions
// were wrong at once.
//
//	MISSING ANCESTOR → 3. The predicate tested only the LEXICAL parent, so
//	/nonexistent-top/x answered 2: an operator setting BURROWEE_LINK_DIR on a
//	host with no /opt/burrowee was told the ownership could not be established
//	and sent to `command -v stat`, and assert_system_tree's rc 3 branch — the
//	one that says "re-run from an interactive terminal so the directory can be
//	created as root" — became unreachable for any root whose parent is missing.
//
//	PRESENT BUT UNRESOLVABLE → 2. A symlink loop, a dangling link, or a root
//	parked on an unmounted volume is a name that is OCCUPIED. Answering 3
//	there tells an operator to create a directory where something already sits.
//
// One observable settles each: walking UP to the nearest ancestor that exists
// separates absent from unreachable, and `[ -L ]` — which does not follow —
// separates unresolvable from absent. dir_probe_reason owns both.
//
// Mutations that redden it:
//   - drop the `[ -L "$_dpr_p" ]` test from dir_probe_reason: the dangling and
//     ELOOP cases answer 3;
//   - put `[ -L ]` back BEFORE `[ -e ]`, at the leaf or in the ancestor walk:
//     the symlink-onto-a-file cases answer 2, which is the stat-dialect block
//     printed about a path whose only problem is that it is a file;
//   - replace dir_probe_reason's ancestor loop with a single lexical parent
//     test: the two missing-ancestor cases answer 2.
func TestDirIsRootSecureSeparatesAbsentFromUnresolvable(t *testing.T) {
	root := canonicalTempDir(t)
	if err := os.MkdirAll(filepath.Join(root, "a", "real"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "a", "afile"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	dangling := filepath.Join(root, "dangling")
	if err := os.Symlink(filepath.Join(root, "no-such-tree"), dangling); err != nil {
		t.Fatal(err)
	}
	// A link that LANDS ON SOMETHING, just not a directory. `[ -e ]` follows,
	// so it is what separates this from the dangling case above — and asking
	// `[ -L ]` first called it unresolvable, printing the whole stat-dialect
	// block about a path whose only problem is that it is a file.
	linkToFile := filepath.Join(root, "link-to-file")
	if err := os.Symlink(filepath.Join(root, "a", "afile"), linkToFile); err != nil {
		t.Fatal(err)
	}
	ancLink := filepath.Join(root, "anclink")
	if err := os.Symlink(filepath.Join(root, "a", "afile"), ancLink); err != nil {
		t.Fatal(err)
	}
	// A chain longer than either kernel's SYMLOOP_MAX: present at its name,
	// and resolvable by nobody.
	prev := filepath.Join(root, "a", "real")
	var loop string
	for i := 0; i < 70; i++ {
		loop = filepath.Join(root, "loop"+strconv.Itoa(i))
		if err := os.Symlink(prev, loop); err != nil {
			t.Fatal(err)
		}
		prev = loop
	}
	none := map[string]string{}
	for _, tc := range []struct {
		name, target string
		want         int
	}{
		{"a missing top-level ancestor", "/nonexistent-top/x", 3},
		{"a missing ancestor further down", filepath.Join(root, "a", "nodir", "deeper"), 3},
		{"a plain missing leaf", filepath.Join(root, "a", "nodir"), 3},
		{"a regular file — no directory is there", filepath.Join(root, "a", "afile"), 3},
		{"a symlink onto a regular file — it lands on something", linkToFile, 3},
		{"an ancestor that is a symlink onto a regular file", filepath.Join(ancLink, "below"), 3},
		{"an ancestor that is a plain regular file", filepath.Join(root, "a", "afile", "below"), 3},
		{"a dangling symlink — the name is occupied", dangling, 2},
		{"a chain past SYMLOOP_MAX — present, unresolvable", loop, 2},
		{"a real directory, for contrast", filepath.Join(root, "a", "real"), 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := dirIsRootSecure(t, tc.target, none, none); got != tc.want {
				t.Errorf("dir_is_root_secure(%s) = %d, want %d", tc.target, got, tc.want)
			}
		})
	}
}

// TestDirLeafIsNotdirSeparatesATakenNameFromAMissingOne — the caller-facing
// half of a distinction dir_probe_reason draws and the call sites used to throw
// away. `notdir` and `absent` both answer code 3, correctly: 3 says "there is
// no DIRECTORY here". But an operator reading "does not exist on this host"
// about a regular file sitting right there at $LINK_DIR is being told
// something false, and separating those two is the whole reason
// dir_probe_reason asks `[ -e ]` before `[ -L ]`.
//
// Mutations that redden it: drop the `[ -e ]` test from dir_probe_reason, or
// put it back after `[ -L ]` — the symlink-onto-a-file case stops being
// notdir; or change dir_leaf_is_notdir to compare against `absent`.
func TestDirLeafIsNotdirSeparatesATakenNameFromAMissingOne(t *testing.T) {
	root := canonicalTempDir(t)
	if err := os.MkdirAll(filepath.Join(root, "adir"), 0o755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(root, "afile")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	linkToFile := filepath.Join(root, "link-to-file")
	if err := os.Symlink(file, linkToFile); err != nil {
		t.Fatal(err)
	}
	dangling := filepath.Join(root, "dangling")
	if err := os.Symlink(filepath.Join(root, "no-such"), dangling); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, target string
		want         bool
	}{
		{"a regular file — the name is taken", file, true},
		{"a symlink onto a regular file — still taken", linkToFile, true},
		{"a directory", filepath.Join(root, "adir"), false},
		{"nothing at all — absent, not taken", filepath.Join(root, "no-such"), false},
		{"a dangling symlink — unresolvable, not taken", dangling, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := dirLeafIsNotdir(t, tc.target); got != tc.want {
				t.Errorf("dir_leaf_is_notdir(%s) = %v, want %v", tc.target, got, tc.want)
			}
		})
	}
}

// TestDirIsRootSecureRefusesAnEmptyOperand — an unset variable must never come
// back "root-secure".
//
// dir_spelling_normalize restores "/" after a spelling like "/." empties it,
// and that restoration fired for an EMPTY INPUT too: `dir_is_root_secure ""`
// answered 0. A rule written for one input shape firing on another, for the
// third time in this change. The in-tree callers all pass ${VAR:-default}, but
// this region is copied byte-for-byte into two other repos and its own header
// says the callers may differ freely, so a caller with an unset variable got a
// pass instead of a refusal.
//
// Mutation that reddens it: drop the `case "$1" in /*)` guard around the
// restoration — "" then normalizes to "/" and answers 0.
//
// There is deliberately only ONE guard. An explicit `[ -n "$1" ] || return 3`
// in dir_is_root_secure was written first and removed: with the normalizer
// guarded, deleting it left this test green, and with it present, deleting the
// normalizer's guard left this test green too. Two statements of one rule make
// neither of them testable, so the rule lives where it fixes the source — in
// the normalizer, for every caller of it in all three repos, not only for this
// predicate.
func TestDirIsRootSecureRefusesAnEmptyOperand(t *testing.T) {
	none := map[string]string{}
	if rc := dirIsRootSecure(t, "", none, none); rc != 3 {
		t.Errorf("dir_is_root_secure(\"\") = %d, want 3 — an unset operand names no directory, and 0 is the one answer it must never get", rc)
	}
	// The restoration it was guarding still works: "/." names the root.
	for _, spelling := range []string{"/", "/.", "/./", "//", "//."} {
		if rc := dirIsRootSecure(t, spelling, none, none); rc != 0 {
			t.Errorf("dir_is_root_secure(%q) = %d, want 0 — the guard must not cost the root spellings it exists for", spelling, rc)
		}
	}
}

// TestDirIsRootSecureSaysUndecidableWhenItCannotTraverse is the 1-vs-2 split at
// the place the downward walk introduced a new way to lose it.
//
// `[ -d X ]` answers false for two facts that must not be collapsed: X is not a
// directory (1, a real answer about a real path), and this process cannot
// SEARCH X's parent to find out (2, nothing is known). The second is ORDINARY
// here rather than exotic — the walk descends through directories it has just
// judged root-owned, and a root-owned 0700 one, which is $SYS_DATA_DIR's own
// shape, passes that judgement and is then unsearchable by the unprivileged
// operator these installers run as. The cd-based form this walk replaced
// answered 2; collapsing it to 1 tells an operator to go and audit permissions
// that are exactly right, which is the misdirection the whole 1-vs-2 contract
// exists to prevent. link_operator_bins reaches it without any root gate.
//
// This test is REAL only below root — root searches a 0000 directory anyway,
// the entry `[ -d ]` then succeeds and the walk answers 0 from stub defaults.
// So it SKIPS under a root runner rather than failing there: a red test that
// is not a defect trains a reader to ignore the colour. CI runs as an ordinary
// uid, where it is a real assertion. There is no euid-independent structural
// half available here the way there is for the never-enters rule.
//
// Mutation that reddens it: make dir_probe_reason answer `absent` instead of
// `unreachable` when the nearest existing ancestor is not searchable — the
// answer becomes 3, "this directory does not exist", about one that does.
//
// WHERE THIS ACTUALLY BITES, stated precisely, because the review's mechanism
// was one step off. The ENTRY test is the reachable instance: `[ -d ]` on the
// leaf is EACCES when an ancestor is unsearchable, and the code answered 3
// there, not 1 — "no such directory" about one that exists. The copy of the
// same split inside dir_level_is_root_secure is NOT reachable in a
// single-threaded run: if the entry `[ -d ]` succeeded, the kernel resolved the
// whole path, so every directory the walk then judges is searchable by
// construction. It is kept as a guard on the window BETWEEN the entry test and
// the walk — separate syscalls, and a directory can be chmod'ed between them —
// and no deterministic test can reach it, exactly like the hop bound. It is
// documented rather than covered; restoring `[ -d "$1" ] || return 1` there
// leaves this suite green, and that is a statement about reachability, not a
// hole in the test.
func TestDirIsRootSecureSaysUndecidableWhenItCannotTraverse(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: no chmod can make a directory unsearchable for this process, so the fixture cannot stage the condition under test")
	}
	root := canonicalTempDir(t)
	sealed := filepath.Join(root, "sealed")
	inner := filepath.Join(sealed, "burrowee")
	if err := os.MkdirAll(inner, 0o755); err != nil {
		t.Fatal(err)
	}
	// Registered after t.TempDir's own cleanup, so it runs BEFORE it and the
	// tree can still be removed.
	t.Cleanup(func() { _ = os.Chmod(sealed, 0o755) })
	if err := os.Chmod(sealed, 0o000); err != nil {
		t.Fatal(err)
	}
	none := map[string]string{}
	// The sealed directory itself is root-owned 0700 to the stub — it passes,
	// and the walk descends into a component it cannot reach.
	modes := map[string]string{sealed: "700"}
	if rc := dirIsRootSecure(t, inner, none, modes); rc != 2 {
		t.Errorf("a component below an unsearchable root-owned directory: rc = %d, want 2 (undecidable) — 1 would send the operator to audit permissions that are correct, and 3 would claim a directory that exists is absent", rc)
	}
	// The sealed directory itself still answers normally: the refusal is about
	// what cannot be reached THROUGH it, not about it.
	if rc := dirIsRootSecure(t, sealed, none, modes); rc != 0 {
		t.Errorf("the unsearchable directory itself: rc = %d, want 0 — it is root-owned 0700, which is exactly the shape $SYS_DATA_DIR has", rc)
	}
}

// canonicalTempDir is t.TempDir() with every symlink in it resolved.
//
// It exists because of a trap that produces a FALSE GREEN on macOS and cannot
// produce one on Linux, so CI alone never finds it: t.TempDir() hands back
// /var/folders/… while /var is a symlink to private/var, and every path this
// predicate judges is physical (/private/var/folders/…). A fixture keyed on
// the unresolved spelling therefore never matches a single row of the stub's
// tables — every uid lookup falls through to 0 and every mode lookup to 0755,
// which is precisely "a correctly-installed root-owned tree", so every case
// that expects a REFUSAL passes for the wrong reason. On Linux /tmp is a real
// directory and the two spellings coincide, which is why a green CI run is not
// evidence here. TestDirRootSecureFixturesReachTheStatStub asserts the fixture
// is actually consulted rather than trusting that it is.
func canonicalTempDir(t *testing.T) string {
	t.Helper()
	d, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// shellFuncBody returns the text of one shell function defined in the contract
// region, brace to brace, so an assertion can be made about the code itself
// rather than about a transcription of it.
func shellFuncBody(t *testing.T, region, name string) string {
	t.Helper()
	open := "\n" + name + "() {\n"
	b := strings.Index(region, open)
	if b < 0 {
		t.Fatalf("the contract region defines no %s()", name)
	}
	rest := region[b+len(open):]
	e := strings.Index(rest, "\n}\n")
	if e < 0 {
		t.Fatalf("%s() is never closed", name)
	}
	return rest[:e]
}

// TestDirRootSecureFixturesReachTheStatStub is the guard on every other case in
// this file: it states a deviation the stub can only report if the fixture path
// the test builds is byte-identical to the path the predicate walks. If the two
// spellings drift — the /var vs /private/var trap canonicalTempDir exists for —
// the stub answers its defaults, the predicate says "secure", and every
// refusal-expecting case in this file goes green while asserting nothing.
//
// Mutation that reddens it: drop the uid test from dir_level_is_root_secure.
func TestDirRootSecureFixturesReachTheStatStub(t *testing.T) {
	root := canonicalTempDir(t)
	if resolved, err := filepath.EvalSymlinks(root); err != nil || resolved != root {
		t.Fatalf("the fixture root is not canonical: %q resolves to %q (err %v)", root, resolved, err)
	}
	leaf := filepath.Join(root, "burrowee")
	if err := os.MkdirAll(leaf, 0o755); err != nil {
		t.Fatal(err)
	}
	// The stub's default answer for an unlisted path is uid 0 / mode 0755, so
	// a table row that is never consulted is indistinguishable from no row at
	// all — except by the verdict, which is what this asserts.
	if rc := dirIsRootSecure(t, leaf, map[string]string{root: "501"}, map[string]string{}); rc != 1 {
		t.Fatalf("a fixture row on %s did not change the verdict: rc = %d, want 1 — the stub is not being consulted for the paths this predicate walks, and every refusal case in this file is passing for the wrong reason", root, rc)
	}
}

// TestDirIsRootSecureJudgesEverySubstitutableComponent is the regression test
// for the defect this file's predicate was rewritten to remove.
//
// The property: dir_is_root_secure answers 0 only if EVERY directory that could
// be substituted for ANY component of the path is root-owned and unwritable by
// non-root — every component of the path as spelled, every component of the
// path it resolves to, and the chain holding each symlink met on the way.
//
// The defect: the predicate resolved the leaf's parent physically
// (`cd "$(dirname …)" && pwd -P`) and walked upward from the result. Physical
// resolution ERASES intermediate symlinks, so an ancestor symlink was never
// stat'ed and the chain that HELD it was never walked. The `[ -L ]` both-chains
// rule added afterwards covered the LEAF only, and the leaf was never the
// substitutable component.
//
// The exploit, spelled out by the fixture below: /usr is group-writable,
// /usr/local is a symlink into a root-owned /opt/burrowee-local, and
// /usr/local/bin is asked about. The collapsed chain — /opt/burrowee-local/bin,
// /opt, / — is spotless, so the install proceeds; then any member of /usr's
// group repoints /usr/local at a tree they own and takes the identity and
// host-cert directory root is about to create, and the exec root root will run
// binaries from. Verified against the pre-fix text: the two cases marked
// "answered 0 before" did exactly that.
//
// Mutations that redden it, by case:
//   - "holder of the ancestor symlink is group-writable" and "holder of the
//     ancestor symlink is not root-owned": restore the collapse — make
//     dir_is_root_secure walk `"$(cd "$(dirname "$_ds_in")" && pwd -P)"` instead
//     of the components of "$_ds_in" — and ONLY these two redden, which is the
//     whole point: they are the two the old form could not see;
//   - every case: delete the `|| return $?` from the walk's
//     dir_level_is_root_secure call;
//   - the group-writable cases: delete the mode test from
//     dir_level_is_root_secure; the uid case: delete its uid test;
//   - "a symlink is judged by its holder, not by its own bits": delete the
//     `[ -L "$_ds_cur" ]` branch, so the link itself is stat'ed — 0777 on
//     Linux, and here whatever the table says.
func TestDirIsRootSecureJudgesEverySubstitutableComponent(t *testing.T) {
	root := canonicalTempDir(t)
	usr := filepath.Join(root, "usr")
	opt := filepath.Join(root, "opt")
	physicalDir := filepath.Join(opt, "burrowee-local")
	if err := os.MkdirAll(filepath.Join(physicalDir, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(usr, 0o755); err != nil {
		t.Fatal(err)
	}
	// /usr/local -> /opt/burrowee-local, absolute, exactly as the affected
	// host spells it.
	absLink := filepath.Join(usr, "local")
	if err := os.Symlink(physicalDir, absLink); err != nil {
		t.Fatal(err)
	}
	// /usr/local-rel -> ../opt/burrowee-local — the same substitution written
	// relatively, which takes the other half of the resolution branch.
	relLink := filepath.Join(usr, "local-rel")
	if err := os.Symlink(filepath.Join("..", "opt", "burrowee-local"), relLink); err != nil {
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
		{"both chains root-owned 0755", filepath.Join(absLink, "bin"), none, none, 0},
		{"holder of the ancestor symlink is group-writable (answered 0 before)",
			filepath.Join(absLink, "bin"), none, map[string]string{usr: "775"}, 1},
		{"holder of the ancestor symlink is not root-owned (answered 0 before)",
			filepath.Join(absLink, "bin"), map[string]string{usr: "501"}, none, 1},
		{"the resolved target's parent is group-writable",
			filepath.Join(absLink, "bin"), none, map[string]string{opt: "775"}, 1},
		{"the resolved target itself is group-writable",
			filepath.Join(absLink, "bin"), none, map[string]string{physicalDir: "775"}, 1},
		{"the leaf below the resolved target is world-writable",
			filepath.Join(absLink, "bin"), none, map[string]string{filepath.Join(physicalDir, "bin"): "757"}, 1},
		{"a symlink is judged by its holder, not by its own bits",
			filepath.Join(absLink, "bin"), map[string]string{absLink: "501"}, map[string]string{absLink: "777"}, 0},
		{"a RELATIVE ancestor symlink resolves the same way", filepath.Join(relLink, "bin"), none, none, 0},
		{"holder of a RELATIVE ancestor symlink is group-writable",
			filepath.Join(relLink, "bin"), none, map[string]string{usr: "775"}, 1},
		{"the target of a RELATIVE ancestor symlink is group-writable",
			filepath.Join(relLink, "bin"), none, map[string]string{physicalDir: "775"}, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := dirIsRootSecure(t, tc.target, tc.uids, tc.modes); got != tc.want {
				t.Errorf("dir_is_root_secure(%s) = %d, want %d", tc.target, got, tc.want)
			}
		})
	}
}

// TestDirIsRootSecureNeverEntersTheDirectoryItJudges holds constraint the
// predicate has already been broken by once: these installers run UNPRIVILEGED
// and elevate per step, and the directory they ask about is routinely
// root-owned 0700 ($SYS_DATA_DIR). A form that resolved the path by entering it
// took EACCES for the operator and refused every non-root install, blaming the
// `stat` dialect.
//
// Both halves are needed, because neither is sufficient alone:
//
//   - BEHAVIOURAL: a leaf with mode 0000 is unsearchable by its owner, so any
//     `cd`, `ls` or glob inside it fails — while `[ -d ]`, `[ -L ]`, `readlink`
//     and `stat` on it need search permission on its PARENT only, and succeed.
//     This half is real for every runner below root (CI runs as an ordinary
//     uid) and vacuous for a root runner, which is what the second half covers.
//   - STRUCTURAL: neither dir_is_root_secure NOR dir_level_is_root_secure
//     contains a `cd` at all. This is euid-independent, so it cannot go
//     quietly vacuous the way a permission fixture can. Both bodies are
//     inspected because the walk calls the helper once per component: a `cd`
//     placed there would enter the leaf just as surely, and checking only the
//     walk would leave the behavioural half — vacuous under a root runner — as
//     the sole cover.
//
// Mutations that redden it: insert `cd "$_ds_in" || return 2` into
// dir_is_root_secure, or `cd "$1" || return 2` into dir_level_is_root_secure
// (each reddens the structural half always, and the behavioural half whenever
// the suite runs below root).
func TestDirIsRootSecureNeverEntersTheDirectoryItJudges(t *testing.T) {
	root := canonicalTempDir(t)
	leaf := filepath.Join(root, "burrowee", "var")
	if err := os.MkdirAll(leaf, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(leaf, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(leaf, 0o755) })
	if rc := dirIsRootSecure(t, leaf, map[string]string{}, map[string]string{leaf: "700"}); rc != 0 {
		t.Errorf("a root-owned 0700 leaf probed by an unprivileged operator: rc = %d, want 0 — the predicate entered the directory instead of stat'ing it from outside", rc)
	}
	region := rootSecureContractRegion(t)
	for _, fn := range []string{"dir_is_root_secure", "dir_level_is_root_secure", "dir_spelling_normalize", "dir_leaf_is_symlink", "dir_probe_reason"} {
		for i, line := range strings.Split(shellFuncBody(t, region, fn), "\n") {
			code := strings.TrimSpace(line)
			if code == "" || strings.HasPrefix(code, "#") {
				continue
			}
			if strings.Contains(code, "cd ") {
				t.Errorf("%s line %d changes directory: %q — the leaf is routinely root-owned 0700 and entering it is EACCES for the operator this installer runs as", fn, i+1, code)
			}
		}
	}
}

// TestDirIsRootSecureJudgesTheWorkingDirectoryOfARelativeSpelling covers the
// branch that turns a relative spelling into an absolute one.
//
// It is here because the branch had NO coverage at all: replacing the whole
// `_ds_cwd="$(pwd -P …)"` … `_ds_rest="${_ds_cwd%/}/$_ds_in"` body with
// `_ds_rest="/$_ds_in"` — judging the path as if it hung off / — left
// `go test -run TestDir` green, while a directory under a group-writable
// working directory reported SECURE. Every input to this predicate has to be
// driven, and the working directory is an input: the components of the cwd are
// components of the path, so whoever can write one of them can move the whole
// relative spelling somewhere else.
//
// Mutations that redden it:
//   - `_ds_rest="/$_ds_in"` in place of the relative branch: the clean case
//     answers 1 (there is no /local) instead of 0;
//   - delete the mode test from dir_level_is_root_secure: the three
//     group-writable cases;
//   - delete its uid test: the not-root-owned case.
func TestDirIsRootSecureJudgesTheWorkingDirectoryOfARelativeSpelling(t *testing.T) {
	root := canonicalTempDir(t)
	usr := filepath.Join(root, "usr")
	if err := os.MkdirAll(filepath.Join(usr, "local", "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	none := map[string]string{}
	cases := []struct {
		name  string
		cwd   string
		arg   string
		uids  map[string]string
		modes map[string]string
		want  int
	}{
		{"a relative spelling under a root-owned working directory", usr, "local/bin", none, none, 0},
		{"the working directory itself is group-writable", usr, "local/bin", none, map[string]string{usr: "775"}, 1},
		{"a component ABOVE the working directory is group-writable", usr, "local/bin", none, map[string]string{root: "775"}, 1},
		{"a component above the working directory is not root-owned", usr, "local/bin", map[string]string{root: "501"}, none, 1},
		{"a relative spelling carrying . and ..", filepath.Join(usr, "local"), "./../local/bin", none, none, 0},
		{"a relative spelling carrying . and .. above a group-writable directory",
			filepath.Join(usr, "local"), "./../local/bin", none, map[string]string{root: "775"}, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := dirIsRootSecureFrom(t, tc.cwd, tc.arg, tc.uids, tc.modes); got != tc.want {
				t.Errorf("dir_is_root_secure(%s) from %s = %d, want %d", tc.arg, tc.cwd, got, tc.want)
			}
		})
	}
}
