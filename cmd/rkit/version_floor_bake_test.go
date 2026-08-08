package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"unicode"
)

// THE INSTALLER'S VERSION FLOOR — written in versions/<comp>.stamp, baked into
// the four committed public <comp>/install.sh as @MIN_VERSION@, and compared at
// install time. Two statements of one fact, kept in step by tools/gen-bootstraps.sh
// and checked only by shell scripts someone must remember to run — the same
// posture as the payload manifest, the binary lists and the trusted comment
// before each of those was pinned.
//
// THE INVARIANT, established from the code rather than assumed. Two candidates
// were live: floor == stamp, and floor <= stamp. They are not the same test and
// the wrong one either fails every cut or catches nothing. Both hold here, for
// different reasons, so both are asserted — separately, because they fail for
// different causes and carry different fixes:
//
//  1. floor <= stamp is the SAFETY invariant, and it is the one with teeth.
//     The shipped assert_version_floor refuses any resolved tag older than the
//     baked floor. The newest tag a resolver can ever answer with is the
//     component's current stamp — so a floor AHEAD of the stamp is not a drift,
//     it is a total install outage: every install of that component refuses the
//     newest release that exists. Nothing else in the repo checks this
//     direction. TestBakedFloorAcceptsTheCurrentStamp asserts it by executing
//     the shipped predicate, per installer.
//
//  2. floor == stamp is the DRIFT invariant, and it is true here — verified,
//     not assumed. tools/release.sh writes versions/<comp>.stamp
//     (resolve_comp_stamp) and then re-runs gen-bootstraps.sh, which re-renders
//     ALL five bootstraps, BEFORE the [RELEASED] marker commit — so both halves
//     move in one commit. `git show` on the last two cuts shows exactly
//     `gateway/install.sh` + `versions/gateway.stamp` and nothing else. The
//     window in which a newer stamp legitimately outruns its floor therefore
//     does not exist in a COMMITTED tree; the state gen-bootstraps.sh's own
//     header warns about ("ANY merge or rebase that brings in a newer
//     versions/*.stamp must be followed by a re-run") is precisely the bug this
//     is meant to catch, not a state to tolerate.
//
// So (2) is strictly stronger than (1) today. It is not a replacement for it:
// if the release flow ever does grow a legitimate stamp-ahead-of-floor window,
// (2) is the assertion to relax and (1) is the one that must survive, because
// (1) is what the shipped installer actually enforces.
//
// WHY THE SHELL CHECKERS ARE NOT INVOKED WHOLESALE. tools/test-version-floor.sh
// already asserts (2) in its BAKE section — but it also re-renders the
// bootstraps with a deliberately bad floor, so it MUTATES tracked files and
// restores them from a trap; tools/test-tag-binding.sh does the same and
// additionally needs minisign, python3 and zip. Neither can be called from
// `go test ./...`: a plain test run must not rewrite the working tree, and two
// packages doing it concurrently would race. What IS reused is the part that
// matters — the shipped predicate itself, lifted verbatim from the committed
// installer between its BEGIN/END markers and EXECUTED, the same "run the real
// thing" approach trusted_comment_test.go takes with the `expect=` line. Only
// the two-line parsing (read a stamp file, read a `MIN_VERSION="…"` line) is
// written in Go, and parsing is not the logic worth sharing.

// floorBlockRe lifts the shipped version-floor predicate — semver_of, is_semver,
// version_ge, assert_version_floor — out of a committed installer. The markers
// exist already: tools/test-version-floor.sh extracts the same block.
var floorBlockRe = regexp.MustCompile(`(?ms)^# BEGIN version-floor\b.*?^# END version-floor$`)

// bakedFloorRe matches an outer bootstrap's one baked `MIN_VERSION="…"`.
var bakedFloorRe = regexp.MustCompile(`(?m)^MIN_VERSION="([^"]*)"$`)

// floorComponents are the components whose bootstrap bakes a floor: the four
// served by the public GitHub-release template. Derived from the signed set
// minus relay — whose gated channel has no tag to floor (see
// TestRelayBootstrapBakesNoVersionFloor) — so a new public component joins this
// list the day it joins relconfig.
func floorComponents(t *testing.T) []string {
	t.Helper()
	var out []string
	for _, c := range signedComponents(t) {
		if c == "relay" {
			continue
		}
		out = append(out, c)
	}
	sort.Strings(out)
	if len(out) < 4 {
		t.Fatalf("only %d public components (%v) bake a version floor — the signed set looks wrong", len(out), out)
	}
	return out
}

// recordedStamp is versions/<comp>.stamp, whitespace-stripped exactly as
// tools/gen-bootstraps.sh reads it (`tr -d '[:space:]'`).
func recordedStamp(t *testing.T, comp string) string {
	t.Helper()
	return strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			return -1
		}
		return r
	}, readRepoFile(t, "versions/"+comp+".stamp"))
}

// shippedFloorBlock returns the version-floor block of a committed installer,
// failing if the markers are gone or the block no longer defines what it must —
// a renamed marker must break this test loudly, not turn it into a silent skip.
func shippedFloorBlock(t *testing.T, rel string) string {
	t.Helper()
	block := floorBlockRe.FindString(readRepoFile(t, rel))
	if block == "" {
		t.Fatalf("%s has no BEGIN/END version-floor block — this test can no longer execute the shipped comparison", rel)
	}
	for _, fn := range []string{"semver_of", "is_semver", "version_ge", "assert_version_floor"} {
		if !strings.Contains(block, "\n"+fn+"()") {
			t.Fatalf("%s's version-floor block does not define %s()", rel, fn)
		}
	}
	return block
}

// runFloorCheck executes the lifted predicate with the two inputs the shipped
// installer has at that point — the baked $MIN_VERSION and the <comp>/<stamp>
// tag it resolved — and reports whether assert_version_floor accepted the tag.
// `fail`, `ok` and `info` are the installer's own output helpers, stubbed the
// same way tools/test-version-floor.sh stubs them.
func runFloorCheck(t *testing.T, block, floor, tag string) (bool, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "floor.sh")
	if err := os.WriteFile(path, []byte(block), 0o600); err != nil {
		t.Fatal(err)
	}
	const runner = `set -eu
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { :; }
ok()   { :; }
. "$1"
MIN_VERSION="$2"
assert_version_floor "$3"
`
	out, err := exec.Command("sh", "-c", runner, "sh", path, floor, tag).CombinedOutput()
	return err == nil, string(out)
}

// TestBakedFloorAcceptsTheCurrentStamp is the safety invariant, run through the
// shipped code: for every public component, the floor baked into the committed
// installer must accept a tag naming that component's CURRENT stamp. The newest
// release that exists is the only thing a resolver can be asked to serve, so a
// floor the current stamp cannot clear means the published installer refuses
// every release of its own component — an outage for every user, discovered
// after publication, and invisible to review because both files look fine on
// their own.
func TestBakedFloorAcceptsTheCurrentStamp(t *testing.T) {
	for _, comp := range floorComponents(t) {
		t.Run(comp, func(t *testing.T) {
			rel := comp + "/install.sh"
			floor := bakedAssignment(t, rel, "MIN_VERSION")
			tag := comp + "/" + recordedStamp(t, comp)
			if ok, out := runFloorCheck(t, shippedFloorBlock(t, rel), floor, tag); !ok {
				t.Errorf("%s bakes a floor its own newest release cannot clear — every install would refuse %s:\n  floor: %q\n  %s",
					rel, tag, floor, strings.TrimSpace(out))
			}
		})
	}
}

// TestFloorCheckRejectsAFloorAheadOfItsStamp is the negative control for the
// test above: it proves the executed predicate can say no. Without it a broken
// extraction — an empty block, a stubbed-out assert_version_floor — would read
// exactly like four passing components.
func TestFloorCheckRejectsAFloorAheadOfItsStamp(t *testing.T) {
	for _, comp := range floorComponents(t) {
		t.Run(comp, func(t *testing.T) {
			rel := comp + "/install.sh"
			tag := comp + "/" + recordedStamp(t, comp)
			if ok, out := runFloorCheck(t, shippedFloorBlock(t, rel), "v99.0.0.2026.01.01.aaaaaaaa", tag); ok {
				t.Errorf("%s's version-floor block accepted %s under a v99.0.0 floor — the block this test executes is not deciding anything:\n  %s",
					rel, tag, strings.TrimSpace(out))
			}
		})
	}
}

// TestBakedFloorsMatchTheirStamps is the drift invariant: the floor a bootstrap
// was rendered with is byte-equal to the stamp it was rendered from. Stronger
// than the safety check above and separate from it because the cause and the
// fix differ — this one goes red when a merge or rebase brings in a newer
// versions/*.stamp without the re-run of tools/gen-bootstraps.sh that
// gen-bootstraps.sh's own header demands, and the fix is that re-run.
func TestBakedFloorsMatchTheirStamps(t *testing.T) {
	for _, comp := range floorComponents(t) {
		t.Run(comp, func(t *testing.T) {
			rel := comp + "/install.sh"
			want := recordedStamp(t, comp)
			if want == "" {
				t.Fatalf("versions/%s.stamp is empty — the floor has no source", comp)
			}
			if got := bakedAssignment(t, rel, "MIN_VERSION"); got != want {
				t.Errorf("%s is out of step with versions/%s.stamp (re-run tools/gen-bootstraps.sh and commit the result):\n  baked floor: %q\n  stamp:       %q",
					rel, comp, got, want)
			}
		})
	}
}

// TestFloorConsumersAreExactlyThePublicComponents closes the set direction: the
// checks above only prove what they iterate. An installer that gains or loses
// its `MIN_VERSION="…"` line would otherwise drop out of the comparison in
// silence — and an unfloored public bootstrap is the silent-rollback vector the
// floor exists to close.
func TestFloorConsumersAreExactlyThePublicComponents(t *testing.T) {
	root := repoRoot(t)
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("read %s: %v", root, err)
	}
	var got []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		b, err := os.ReadFile(filepath.Join(root, e.Name(), "install.sh"))
		if err != nil {
			continue // not a component bootstrap directory
		}
		if bakedFloorRe.Match(b) {
			got = append(got, e.Name())
		}
	}
	sort.Strings(got)
	if want := floorComponents(t); strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("installers baking a version floor %v, public components %v — every public bootstrap floors its resolver, and a floor belongs to a component with a stamp",
			got, want)
	}
}

// TestRelayBootstrapBakesNoVersionFloor records the one gap, so it stays a known
// shape rather than an oversight: relay's gated channel serves stamp-less
// latest.<os>-<arch>.zip names, so its installer resolves no tag and has nothing
// to floor. It is the same gap TestRelayBootstrapDoesNoVersionBinding records
// for the trusted comment, and it has the same fix — if relay's channel gains
// tag resolution it must gain a floor, and this test goes red so that the
// answer is to add relay to the checks above rather than to delete this.
func TestRelayBootstrapBakesNoVersionFloor(t *testing.T) {
	src := readRepoFile(t, "relay/install.sh")
	if floorBlockRe.MatchString(src) {
		t.Error("relay/install.sh now carries a version-floor block — cross-check its baked floor in TestBakedFloorsMatchTheirStamps")
	}
	if bakedFloorRe.MatchString(src) {
		t.Error("relay/install.sh now bakes a MIN_VERSION — add relay to floorComponents so the floor is pinned to versions/relay.stamp")
	}
}
