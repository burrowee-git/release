package register

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// STAMP-PATTERN DRIFT — spec §4.1's stable/beta stamp-shape regex pair is
// spelled independently in three places in THIS repo:
//
//  1. stableStampPattern / betaStampPattern, above (register.go) — the Go
//     source of truth; internal/register/prune.go correctly reuses these
//     rather than restating them.
//  2. tools/bootstrap.template.sh's TAG_RE case statement — baked into every
//     generated outer bootstrap (cli/gateway/edge/agent ×
//     install.sh/upgrade.sh/updater.install.sh, and any open beta.* twin).
//  3. tools/prune-releases.sh's own inline `pattern=` pair (its GitHub-side
//     retention scan).
//
// A fourth copy lives in the console repo
// (internal/console/release/channel.go's stableStampRe/betaStampRe) — out of
// reach from this repo, so it stays a reviewer's manual cross-check per the
// design spec rather than something this test can pin.
//
// All three same-repo copies agree today. Nothing kept them agreeing before
// this test: a change to one, with the others untouched, compiled and passed
// every other suite clean. Modelled on cmd/rkit/trusted_comment_test.go,
// which closes the same class of gap for the trusted-comment string — extract
// the REAL committed bytes and compare them against the Go side, rather than
// restating the pattern a third time as a literal that could itself drift and
// never be noticed.

// stampPatternRepoRoot resolves this package's directory two levels up to the
// repo root (internal/register -> internal -> root).
func stampPatternRepoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return root
}

// goPatternShape normalizes a Go %s-templated pattern constant to the shape a
// shell TAG_RE uses (a literal placeholder token in place of the format verb),
// so the two can be compared byte-for-byte without either side reasoning about
// the other's substitution syntax.
func goPatternShape(pattern, placeholder string) string {
	return fmt.Sprintf(pattern, placeholder)
}

// tagRELineRe matches one arm of tools/bootstrap.template.sh's TAG_RE case
// statement as baked into a generated outer bootstrap, e.g.:
//
//	beta) TAG_RE="^${COMP}/v[0-9]+\.[0-9]+\.[0-9]+\.beta\.[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9a-f]{8}$" ;;
//	*)    TAG_RE="^${COMP}/v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9a-f]{8}$" ;;
var tagRELineRe = regexp.MustCompile(`(?m)^\s*(beta|\*)\)\s+TAG_RE="([^"]*)"\s*;;\s*$`)

// extractTagRE pulls the beta/stable TAG_RE arms out of a generated outer
// bootstrap's source, keyed "beta"/"stable" (the case statement's "*" arm is
// the stable fallback). Fails loudly on anything other than exactly two arms —
// a bootstrap missing an arm, or carrying a THIRD, is exactly the kind of
// silent drift this test exists to catch, not something to skip past.
func extractTagRE(t *testing.T, label, src string) map[string]string {
	t.Helper()
	out := map[string]string{}
	for _, m := range tagRELineRe.FindAllStringSubmatch(src, -1) {
		key := m[1]
		if key == "*" {
			key = "stable"
		}
		out[key] = m[2]
	}
	if len(out) != 2 {
		t.Fatalf("%s: found %d TAG_RE arm(s) %v, want 2 (beta + stable)", label, len(out), out)
	}
	return out
}

// publicBootstrapFiles discovers every generated outer bootstrap this repo
// currently carries — install.sh/upgrade.sh/updater.install.sh and any open
// beta.* twin, for every public component directory at the repo root. relay
// is excluded: its install.sh is rendered from
// tools/relay-bootstrap.template.sh, a private gated-channel template with no
// @CHANNEL@/TAG_RE at all (see cmd/rkit's TestRelayBootstrapBakesNoMode).
// Discovered rather than restated as a literal component list, so a new
// public component is cross-checked the day its directory appears.
func publicBootstrapFiles(t *testing.T) []string {
	t.Helper()
	root := stampPatternRepoRoot(t)
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range entries {
		if !e.IsDir() || e.Name() == "relay" {
			continue
		}
		// A public component directory always has an install.sh; anything
		// else at the repo root (skills/, dist/, site/, tools/, …) does not
		// and is skipped.
		if _, err := os.Stat(filepath.Join(root, e.Name(), "install.sh")); err != nil {
			continue
		}
		matches, err := filepath.Glob(filepath.Join(root, e.Name(), "*.sh"))
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range matches {
			if filepath.Base(m) == "preflight.sh" {
				continue // OS-dependency installer — not the outer bootstrap, no TAG_RE
			}
			out = append(out, m)
		}
	}
	sort.Strings(out)
	if len(out) == 0 {
		t.Fatal("publicBootstrapFiles found none — did the repo layout move?")
	}
	return out
}

// TestBootstrapTagREMatchesGoStampPatterns pins tools/bootstrap.template.sh's
// TAG_RE — as baked into every committed outer bootstrap — to
// stableStampPattern/betaStampPattern byte-for-byte.
func TestBootstrapTagREMatchesGoStampPatterns(t *testing.T) {
	want := map[string]string{
		"stable": goPatternShape(stableStampPattern, "${COMP}"),
		"beta":   goPatternShape(betaStampPattern, "${COMP}"),
	}
	for _, path := range publicBootstrapFiles(t) {
		rel, err := filepath.Rel(stampPatternRepoRoot(t), path)
		if err != nil {
			t.Fatal(err)
		}
		t.Run(rel, func(t *testing.T) {
			src, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			got := extractTagRE(t, rel, string(src))
			for _, channel := range []string{"stable", "beta"} {
				if got[channel] != want[channel] {
					t.Errorf("%s: %s TAG_RE = %q, want %q (drifted from internal/register.%sStampPattern)",
						rel, channel, got[channel], want[channel], channel)
				}
			}
		})
	}
}

// prunePatternLineRe matches tools/prune-releases.sh's inline `pattern=` line,
// e.g.:
//
//	pattern="^${comp}/v[0-9]+\.[0-9]+\.[0-9]+\.beta\.[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9a-f]{8}\$"
var prunePatternLineRe = regexp.MustCompile(`(?m)^\s*pattern="([^"]*)"\s*$`)

// TestPruneReleasesPatternMatchesGoStampPatterns pins tools/prune-releases.sh's
// own inline stable/beta `pattern=` pair (its GitHub-side retention scan) to
// the same Go constants — the third same-repo copy.
func TestPruneReleasesPatternMatchesGoStampPatterns(t *testing.T) {
	path := filepath.Join(stampPatternRepoRoot(t), "tools", "prune-releases.sh")
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	matches := prunePatternLineRe.FindAllStringSubmatch(string(src), -1)
	if len(matches) != 2 {
		t.Fatalf("tools/prune-releases.sh: found %d pattern= line(s), want 2 (beta + stable)", len(matches))
	}
	// The script assigns the beta arm first (`if [ "${CHANNEL}" = beta ]`),
	// the stable arm second (`else`) — pinned by ORDER, since the shell has
	// no case-arm label like TAG_RE's to key on.
	gotBeta, gotStable := matches[0][1], matches[1][1]

	// prune-releases.sh writes the trailing anchor as `\$` inside a
	// double-quoted string (a literal `$`, just escaped defensively) where
	// TAG_RE and the Go constants write a bare `$` — same regex, different
	// quoting convention. Normalize before comparing.
	gotBeta = strings.ReplaceAll(gotBeta, `\$`, `$`)
	gotStable = strings.ReplaceAll(gotStable, `\$`, `$`)

	wantBeta := goPatternShape(betaStampPattern, "${comp}")
	wantStable := goPatternShape(stableStampPattern, "${comp}")

	if gotBeta != wantBeta {
		t.Errorf("tools/prune-releases.sh beta pattern = %q, want %q (drifted from internal/register.betaStampPattern)", gotBeta, wantBeta)
	}
	if gotStable != wantStable {
		t.Errorf("tools/prune-releases.sh stable pattern = %q, want %q (drifted from internal/register.stableStampPattern)", gotStable, wantStable)
	}
}
