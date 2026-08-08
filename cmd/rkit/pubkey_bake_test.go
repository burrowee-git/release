package main

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// THE RELEASE SIGNING PUBKEY — one source, five baked copies, and until now
// nothing comparing them under a plain `go test ./...`.
//
// burrowee-release.pub is the trust anchor. tools/gen-bootstraps.sh bakes its
// base64 key line into all five outer bootstraps as @PUBKEY@, and each shipped
// installer hands that literal to `minisign -V -P` to verify SHA256SUMS.txt
// before it unzips anything. The key file itself is ALSO served from the static
// channel — so the file and the five installers are five statements of one fact
// with a comment between them, exactly the shape that shipped an empty gateway
// v0.2.0 payload and was closed three times since (payload manifest, binary
// lists, trusted comment).
//
// WHY IT CANNOT BE COLLAPSED TO ONE COPY. The bootstrap is a standalone POSIX-sh
// script curl'd to a stranger's machine; fetching the key at install time from
// the same channel that served the script would add no trust (an attacker who
// controls one controls both) and would add a failure mode (a fetch that can
// fail). Baking it is correct. So the agreement is PINNED here, not collapsed.
//
// WHAT A DRIFT COSTS. Identical to a trusted-comment drift and arguably worse:
// every install of every component fails at the signature gate, for everyone,
// discovered only after the installer is published. Nothing in the shipped
// installer can notice — a wrong-but-well-formed key is indistinguishable from
// the right one until a real signature is checked against it.
//
// WHY THIS IS THE FILE THAT CATCHES IT. `rkit harness` covers this class but
// needs a toolchain, four cross-compiles and a signing key, so nothing invokes
// it. tools/test-tag-binding.sh's DRIFT section re-renders the bootstraps and
// diffs them, which catches a stale key too — but it needs minisign, python3 and
// zip, and it MUTATES tracked files, so it is a script someone must remember to
// run. This is the cheap hermetic half: it reads the committed bytes and
// compares, and it runs on every commit.

// bakedPubkeyRe matches an outer bootstrap's one baked `PUBKEY="…"` assignment.
// Anchored so the several comment lines and the `case "$PUBKEY" in` guard that
// also mention the variable are not mistaken for the assignment.
var bakedPubkeyRe = regexp.MustCompile(`(?m)^PUBKEY="([^"]*)"$`)

// bakedAssignment returns the value of the single top-level `NAME="value"`
// assignment in a committed installer, failing if there is not exactly one —
// a second assignment would mean the shipped script's later value wins and this
// test was pinning the earlier one.
func bakedAssignment(t *testing.T, rel, name string) string {
	t.Helper()
	re := regexp.MustCompile(`(?m)^` + regexp.QuoteMeta(name) + `="([^"]*)"$`)
	hits := re.FindAllStringSubmatch(readRepoFile(t, rel), -1)
	if len(hits) != 1 {
		t.Fatalf("%s has %d `%s=\"…\"` assignments, want exactly 1", rel, len(hits), name)
	}
	return hits[0][1]
}

// releasePubkey is the base64 key line of burrowee-release.pub, read by the same
// rule tools/gen-bootstraps.sh bakes with: drop the `untrusted comment:` header
// and any blank line, keep what is left. A minisign public key file is exactly
// those two lines, so what is left must be exactly ONE line — the generator ends
// its pipeline with `tail -n1`, which would silently pick the last of several
// and leave this test pinning to whichever it picked.
func releasePubkey(t *testing.T) string {
	t.Helper()
	var keys []string
	for _, line := range strings.Split(readRepoFile(t, "burrowee-release.pub"), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "untrusted comment:") {
			continue
		}
		keys = append(keys, line)
	}
	if len(keys) != 1 {
		t.Fatalf("burrowee-release.pub holds %d key lines %q, want exactly 1", len(keys), keys)
	}
	return keys[0]
}

// pubkeyConsumers discovers, rather than restates, which top-level
// <comp>/install.sh bake a pubkey. Discovery is the point: a sixth component's
// bootstrap is cross-checked the day its directory appears, and one that stops
// baking a key is noticed instead of being quietly dropped from the loop.
func pubkeyConsumers(t *testing.T) []string {
	t.Helper()
	root := repoRoot(t)
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("read %s: %v", root, err)
	}
	var comps []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		b, err := os.ReadFile(filepath.Join(root, e.Name(), "install.sh"))
		if err != nil {
			continue // not a component bootstrap directory
		}
		if bakedPubkeyRe.Match(b) {
			comps = append(comps, e.Name())
		}
	}
	sort.Strings(comps)
	return comps
}

// TestEveryInstallerBakesTheReleasePubkey is the cross-check: the committed
// bootstraps — the exact bytes served from the static channel — verify against
// the key in burrowee-release.pub, which is the key releases are signed with.
// Includes relay's, whose gated channel is a different template but the same
// minisign trust anchor.
func TestEveryInstallerBakesTheReleasePubkey(t *testing.T) {
	want := releasePubkey(t)
	for _, comp := range signedComponents(t) {
		t.Run(comp, func(t *testing.T) {
			rel := comp + "/install.sh"
			if got := bakedAssignment(t, rel, "PUBKEY"); got != want {
				t.Errorf("%s verifies against a different key than releases are signed with (re-run tools/gen-bootstraps.sh):\n  baked:                 %q\n  burrowee-release.pub:  %q",
					rel, got, want)
			}
		})
	}
}

// TestPubkeyConsumersAreExactlyTheSignedComponents closes the set direction:
// the cross-check above only proves what it iterates. If a component gains a
// bootstrap, or an existing one loses its `PUBKEY="…"` line to a refactor, that
// installer would drop out of the comparison silently.
func TestPubkeyConsumersAreExactlyTheSignedComponents(t *testing.T) {
	want := append([]string(nil), signedComponents(t)...)
	sort.Strings(want)
	got := pubkeyConsumers(t)
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("installers baking a pubkey %v, components %v — every component's bootstrap bakes the trust anchor, and every baked anchor belongs to a component",
			got, want)
	}
}

// TestReleasePubkeyIsTheRealKeyNotATestOrPlaceholderKey guards the source of
// truth itself, which the cross-check above cannot: if burrowee-release.pub were
// replaced, all five installers would agree with it and still be wrong.
//
// This is not hypothetical. tools/gen-bootstraps.sh falls back to
// tools/testkeys/test.pub when no release key is present, and
// $BURROWEE_PUBKEY_FILE overrides it — tools/test-preflight.sh renders with the
// TEST key and, unlike test-e2e-relay.sh and test-version-floor.sh, restores
// nothing on exit, so it leaves test-keyed bootstraps in the working tree for
// the next `git add`. The shipped runtime guard would not catch it either: it
// rejects only ""/*REPLACE*/*PLACEHOLDER*/*TEMP*, and a real test key is none of
// those. It is a well-formed key that verifies nothing we sign.
func TestReleasePubkeyIsTheRealKeyNotATestOrPlaceholderKey(t *testing.T) {
	key := releasePubkey(t)

	testKey := ""
	for _, line := range strings.Split(readRepoFile(t, "tools/testkeys/test.pub"), "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "untrusted comment:") {
			testKey = line
		}
	}
	if testKey == "" {
		t.Fatal("tools/testkeys/test.pub holds no key line — this test can no longer tell the test key from the release key")
	}
	if key == testKey {
		t.Fatalf("burrowee-release.pub holds the TEST key %q — the published installers would verify against a key nothing we release is signed with (restore the real key; see tools/test-preflight.sh, which renders with the test key and restores nothing)", key)
	}

	// The same shapes the shipped installers' own guard refuses, asserted at the
	// source so a placeholder never reaches a render in the first place.
	for _, bad := range []string{"REPLACE", "PLACEHOLDER", "TEMP"} {
		if strings.Contains(key, bad) {
			t.Errorf("burrowee-release.pub holds %q, a %s placeholder — every generated installer would abort at its own guard", key, bad)
		}
	}
}
