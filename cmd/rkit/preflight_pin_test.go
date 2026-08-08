package main

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// THE PREFLIGHT CHECKSUM — a third instance of the shape this branch was opened
// to close, found while closing the two that were known.
//
// tools/gen-bootstraps.sh renders <comp>/preflight.sh, hashes it, and bakes that
// hash into <comp>/install.sh as @PREFLIGHT_SHA256@. Both halves are COMMITTED
// files served side by side from the static channel, and the shipped installer
// downloads preflight.sh and refuses to run it unless it hashes to the baked
// value — preflight runs BEFORE minisign exists, so this pin is its only
// integrity anchor.
//
// Which makes it the same duplication as @PUBKEY@ and @MIN_VERSION@, with the
// same enforcement gap: the two halves are kept in step by one generator, and
// checked only by tools/test-tag-binding.sh's DRIFT section — which re-renders
// every bootstrap and diffs it, needs minisign, python3 and zip, and MUTATES
// tracked files. Nothing invokes it routinely. A half-regenerated pair (one file
// staged, the other not; a hand-edit to a generated preflight) breaks every
// install of that component at the preflight gate, after publication.
//
// It is also the cheapest of the three to pin: both halves are in the tree, so
// the check is a sha256 of a committed file. No toolchain, no render, no key.

// bakedPreflightRe matches an outer bootstrap's one baked PREFLIGHT_SHA256.
var bakedPreflightRe = regexp.MustCompile(`(?m)^PREFLIGHT_SHA256="([^"]*)"$`)

// digestOf is what tools/gen-bootstraps.sh's sha256_of computes — `shasum -a
// 256` / `sha256sum` over the rendered file — and what the shipped installer
// recomputes over the copy it downloaded. Hashed with rkit's own sha256Hex
// (cmd/rkit/diff.go), not a second implementation of it.
func digestOf(t *testing.T, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(repoRoot(t), rel))
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	return sha256Hex(b)
}

// TestBakedPreflightHashesMatchTheCommittedPreflights is the cross-check: the
// hash an installer pins is the hash of the preflight.sh committed beside it —
// the two files the static channel serves as a pair.
func TestBakedPreflightHashesMatchTheCommittedPreflights(t *testing.T) {
	for _, comp := range floorComponents(t) {
		t.Run(comp, func(t *testing.T) {
			install, preflight := comp+"/install.sh", comp+"/preflight.sh"
			want := digestOf(t, preflight)
			if got := bakedAssignment(t, install, "PREFLIGHT_SHA256"); got != want {
				t.Errorf("%s pins a hash that is not %s's (re-run tools/gen-bootstraps.sh and commit BOTH files):\n  pinned:   %s\n  actual:   %s",
					install, preflight, got, want)
			}
		})
	}
}

// TestBakedPreflightHashIsARealDigest guards the shape, which the comparison
// above cannot: an empty or placeholder pin would compare equal to nothing and
// is what the shipped installer's own guard (""/*PLACEHOLDER*/*TEMP*) refuses at
// runtime — by which point it is already published.
func TestBakedPreflightHashIsARealDigest(t *testing.T) {
	digest := regexp.MustCompile(`^[0-9a-f]{64}$`)
	for _, comp := range floorComponents(t) {
		t.Run(comp, func(t *testing.T) {
			rel := comp + "/install.sh"
			got := bakedAssignment(t, rel, "PREFLIGHT_SHA256")
			if !digest.MatchString(got) {
				t.Errorf("%s pins %q, which is not a lowercase sha256 — the installer would abort at its own guard rather than run preflight", rel, got)
			}
		})
	}
}

// TestPreflightPairsAreExactlyThePublicComponents closes the set direction, and
// the pairing: a preflight.sh with no installer pinning it is unverifiable, and
// an installer pinning a preflight.sh that is not there fails every install at
// the fetch. relay is correctly absent from both — its gated bootstrap installs
// no OS dependencies and has no preflight.
func TestPreflightPairsAreExactlyThePublicComponents(t *testing.T) {
	root := repoRoot(t)
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("read %s: %v", root, err)
	}
	var haveFile, havePin []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if _, err := os.Stat(filepath.Join(root, e.Name(), "preflight.sh")); err == nil {
			haveFile = append(haveFile, e.Name())
		}
		b, err := os.ReadFile(filepath.Join(root, e.Name(), "install.sh"))
		if err == nil && bakedPreflightRe.Match(b) {
			havePin = append(havePin, e.Name())
		}
	}
	sort.Strings(haveFile)
	sort.Strings(havePin)
	want := strings.Join(floorComponents(t), " ")
	if strings.Join(haveFile, " ") != want {
		t.Errorf("directories with a preflight.sh %v, public components %v", haveFile, floorComponents(t))
	}
	if strings.Join(havePin, " ") != want {
		t.Errorf("installers pinning a preflight hash %v, public components %v", havePin, floorComponents(t))
	}
}
