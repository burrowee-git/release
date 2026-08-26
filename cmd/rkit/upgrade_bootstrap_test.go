package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// THE HOSTED UPGRADE BOOTSTRAP — <comp>/upgrade.sh, rendered from the SAME
// tools/bootstrap.template.sh as <comp>/install.sh under a @MODE@ substitution.
//
// It is the install path plus one step: resolve + verify + unzip the release
// exactly as install.sh does, run the inner installer, then run
// migrations/upgrade.sh out of the SAME verified kit. Everything that makes the
// template a trust anchor — the baked pubkey, the pinned preflight sha256, the
// version floor — is therefore the same lines, and this file is what proves the
// render did not drop one of them on the way.
//
// AND THE PUBLISH HALF, which is the part this repo keeps getting wrong. A
// generated file nobody uploads is a 404 at a URL we advertise; a generated file
// nobody `git add`s is a marker commit that silently drops the artifact it just
// published. tools/release.sh does both, in TWO places (do_release and the
// distribute-only path), and nothing until now compared the set of files it
// ships against the set the generator writes. TestReleasePublishesEveryRendered
// Artifact discovers the rendered set from the tree rather than restating it, so
// a NEW per-component artifact joins the requirement the day it appears.

// bakedModeRe matches an outer bootstrap's one baked `MODE="…"` assignment.
var bakedModeRe = regexp.MustCompile(`(?m)^MODE="([^"]*)"$`)

// upgradeConsumers discovers which top-level component directories hold an
// upgrade.sh. Discovered, not restated: a component that gains a bootstrap is
// cross-checked the day its directory appears, and one that loses its upgrade.sh
// to a bad merge is noticed rather than quietly dropped from the loop.
func upgradeConsumers(t *testing.T) []string {
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
		if _, err := os.Stat(filepath.Join(root, e.Name(), "upgrade.sh")); err == nil {
			comps = append(comps, e.Name())
		}
	}
	sort.Strings(comps)
	return comps
}

// renderedArtifacts is the set of per-component files tools/gen-bootstraps.sh
// writes for the public components — DISCOVERED from the tree, by intersecting
// what each public component directory actually holds. Intersection, not union:
// a stray file in one directory is that directory's problem, while a file every
// public component has is by construction something the generator produced for
// all of them, and therefore something release.sh must ship for all of them.
func renderedArtifacts(t *testing.T) []string {
	t.Helper()
	root := repoRoot(t)
	counts := map[string]int{}
	comps := floorComponents(t)
	for _, comp := range comps {
		entries, err := os.ReadDir(filepath.Join(root, comp))
		if err != nil {
			t.Fatalf("read %s: %v", comp, err)
		}
		for _, e := range entries {
			if !e.IsDir() && strings.HasSuffix(e.Name(), ".sh") {
				counts[e.Name()]++
			}
		}
	}
	var out []string
	for name, n := range counts {
		if n == len(comps) {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	if len(out) < 3 {
		t.Fatalf("only %v is rendered for every public component %v — expected at least install.sh, preflight.sh and upgrade.sh", out, comps)
	}
	return out
}

// partialRenderedArtifacts is the set of per-component files
// tools/gen-bootstraps.sh writes for SOME but not all public components —
// present in at least one floorComponents() directory and absent from at
// least one other (e.g. updater.install.sh: edge/gateway only). It exists
// because renderedArtifacts()'s intersection is blind to these BY
// CONSTRUCTION — a file in 2 of 4 directories never reaches n==len(comps) —
// which is exactly how updater.install.sh escaped the publish guard the
// first time it was added: generated, committed, never uploaded, and the
// guard written to make that impossible never saw it. Returns a map from
// artifact name to the SORTED list of components that actually have it, so a
// caller can name exactly which ones without re-deriving it.
func partialRenderedArtifacts(t *testing.T) map[string][]string {
	t.Helper()
	root := repoRoot(t)
	comps := floorComponents(t)
	owners := map[string][]string{}
	for _, comp := range comps {
		entries, err := os.ReadDir(filepath.Join(root, comp))
		if err != nil {
			t.Fatalf("read %s: %v", comp, err)
		}
		for _, e := range entries {
			if !e.IsDir() && strings.HasSuffix(e.Name(), ".sh") {
				owners[e.Name()] = append(owners[e.Name()], comp)
			}
		}
	}
	out := map[string][]string{}
	for name, list := range owners {
		if len(list) > 0 && len(list) < len(comps) {
			sort.Strings(list)
			out[name] = list
		}
	}
	return out
}

// TestUpgradeBootstrapsAreExactlyThePublicComponents closes the set direction.
//
// THE RULE THIS PINS, stated once so a reader does not have to infer it: an
// upgrade.sh is rendered for EVERY public component, not only for those that
// ship a migration ladder today. Which components have a ladder is a fact about
// the COMPONENT repos' release zips, decided at their cut; this repo renders a
// static file at ITS cut and serves it from a stable URL. Making the render
// conditional would put a per-component "has a ladder" belief in this repo that
// nothing keeps in step with the zips — and the first time it is wrong, the URL
// we advertise 404s. A kit with no ladder is instead a RUNTIME refusal by the
// shipped bootstrap, naming the component and the version it just installed,
// which is a message an operator can act on. relay is correctly absent: its
// gated channel is a different template and is not served from the static
// channel at all.
func TestUpgradeBootstrapsAreExactlyThePublicComponents(t *testing.T) {
	want := floorComponents(t)
	got := upgradeConsumers(t)
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("directories with an upgrade.sh %v, public components %v — every public component's URL is advertised, so every one of them must have the file (re-run tools/gen-bootstraps.sh)", got, want)
	}
}

// TestUpgradeBootstrapBakesTheSameTrustAnchorsAsInstall is the whole point of
// the shared template: the two renders differ in MODE and in nothing that the
// trust chain depends on. A drift here is not cosmetic — an upgrade.sh with a
// stale pubkey fails every signature check, one with a stale preflight pin fails
// every preflight, and one with a stale floor refuses every resolved tag.
func TestUpgradeBootstrapBakesTheSameTrustAnchorsAsInstall(t *testing.T) {
	for _, comp := range floorComponents(t) {
		t.Run(comp, func(t *testing.T) {
			install, upgrade := comp+"/install.sh", comp+"/upgrade.sh"
			for _, name := range []string{"PUBKEY", "MIN_VERSION", "PREFLIGHT_SHA256"} {
				want := bakedAssignment(t, install, name)
				if got := bakedAssignment(t, upgrade, name); got != want {
					t.Errorf("%s bakes %s=%q but %s bakes %q — the two renders must agree (re-run tools/gen-bootstraps.sh and commit BOTH)", upgrade, name, got, install, want)
				}
			}
			// And the preflight pin is not merely EQUAL to install.sh's, it is
			// the real digest: two renders agreeing on a wrong value is exactly
			// the failure an equality-only check cannot see.
			if got, want := bakedAssignment(t, upgrade, "PREFLIGHT_SHA256"), digestOf(t, comp+"/preflight.sh"); got != want {
				t.Errorf("%s pins %s, which is not %s/preflight.sh's digest %s", upgrade, got, comp, want)
			}
		})
	}
}

// TestBakedModeIsRealAndDistinct — the mode split is what makes the two files
// different, so it is the one substitution that must NOT match between them. An
// unsubstituted @MODE@, or an upgrade.sh that renders as mode "install", is a
// file that installs and silently skips the migration half it exists for.
func TestBakedModeIsRealAndDistinct(t *testing.T) {
	for _, comp := range floorComponents(t) {
		t.Run(comp, func(t *testing.T) {
			if got := bakedAssignment(t, comp+"/install.sh", "MODE"); got != "install" {
				t.Errorf("%s/install.sh bakes MODE=%q, want \"install\"", comp, got)
			}
			if got := bakedAssignment(t, comp+"/upgrade.sh", "MODE"); got != "upgrade" {
				t.Errorf("%s/upgrade.sh bakes MODE=%q, want \"upgrade\"", comp, got)
			}
		})
	}
}

// TestRelayBootstrapBakesNoMode guards the other side of the set: relay is
// rendered from a different template with no mode at all, and must not acquire
// one by a copy-paste.
func TestRelayBootstrapBakesNoMode(t *testing.T) {
	if bakedModeRe.MatchString(readRepoFile(t, "relay/install.sh")) {
		t.Error("relay/install.sh bakes a MODE — relay uses tools/relay-bootstrap.template.sh, has no ladder and is not served from the static channel")
	}
}

// scpSites returns the line numbers in tools/release.sh that scp
// <comp>/<artifact> to the release host.
func scpSites(release, artifact string) []int {
	re := regexp.MustCompile(`^\s*scp -q "\$\{REPO_ROOT\}/\$\{comp\}/` + regexp.QuoteMeta(artifact) + `"`)
	var out []int
	for i, line := range strings.Split(release, "\n") {
		if re.MatchString(line) {
			out = append(out, i+1)
		}
	}
	return out
}

// gitAddSites returns the line numbers in tools/release.sh whose `git add`
// stages <comp>/<artifact> into the marker commit.
func gitAddSites(release, artifact string) []int {
	needle := fmt.Sprintf(`"${comp}/%s"`, artifact)
	var out []int
	for i, line := range strings.Split(release, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "git add ") && strings.Contains(trimmed, needle) {
			out = append(out, i+1)
		}
	}
	return out
}

// TestReleasePublishesEveryRenderedArtifact — the step this plan called the one
// most likely to be silently skipped, and the defect this repo shipped twice
// this month in another shape: an artifact that is generated, committed, and
// then never uploaded.
//
// tools/release.sh has TWO paths that publish a component: do_release (produce)
// and the distribute-only path. Each must scp every rendered artifact to the
// static host AND `git add` it into the marker commit — four sites per artifact.
// EXACTLY two of each is asserted, not "at least": a third publish site is a
// path this test has never seen, and a silently-missing one is what it exists to
// catch.
func TestReleasePublishesEveryRenderedArtifact(t *testing.T) {
	release := readRepoFile(t, "tools/release.sh")
	for _, artifact := range renderedArtifacts(t) {
		t.Run(artifact, func(t *testing.T) {
			assertArtifactPublished(t, release, artifact)
		})
	}
	// Non-universal artifacts (present for SOME but not all public components
	// — e.g. updater.install.sh, edge/gateway only) are invisible to
	// renderedArtifacts()'s intersection BY CONSTRUCTION. The publish sites in
	// tools/release.sh are comp-parameterized shell (`${comp}/<artifact>`,
	// guarded with `[ -f … ]` for the components that don't have the file), so
	// the same two-sites-each requirement still applies — this loop is what
	// makes the guard see the artifact class that escaped it once already.
	for artifact, owners := range partialRenderedArtifacts(t) {
		t.Run(artifact, func(t *testing.T) {
			t.Logf("%s is rendered for %v only (not every public component) — still must be published from both sites", artifact, owners)
			assertArtifactPublished(t, release, artifact)
		})
	}
}

// assertArtifactPublished is the two-sites-each requirement shared by the
// universal and partial artifact checks above: tools/release.sh must scp
// ${comp}/<artifact> to the static host and `git add` it into the marker
// commit from EXACTLY two sites (do_release + distribute-only) — not "at
// least", since a third publish site is a path this test has never seen and a
// silently-missing one is what it exists to catch.
func assertArtifactPublished(t *testing.T, release, artifact string) {
	t.Helper()
	if got := scpSites(release, artifact); len(got) != 2 {
		t.Errorf("tools/release.sh scps ${comp}/%s from %d site(s) %v, want 2 (do_release + distribute-only) — a rendered artifact nobody uploads is a 404 at a URL we advertise", artifact, len(got), got)
	}
	if got := gitAddSites(release, artifact); len(got) != 2 {
		t.Errorf("tools/release.sh `git add`s ${comp}/%s at %d site(s) %v, want 2 (do_release + distribute-only) — a rendered artifact the marker commit drops is regenerated-but-uncommitted on the next cut", artifact, len(got), got)
	}
}

// TestTestSuitesRestoreEveryRenderedArtifact — the standing hazard, extended.
//
// tools/test-version-floor.sh, tools/test-tag-binding.sh and
// tools/test-r2-fallback.sh all RE-RENDER the bootstraps with an ephemeral or
// TEST key and restore the checked-in bytes only on a clean exit, from a
// hardcoded file list. An artifact missing from that list is re-rendered with
// the test key and never restored — so a failed run leaves a TEST-keyed file in
// the tree for the next `git add`, which is precisely how a bootstrap that
// verifies nothing we sign reaches a cut.
func TestTestSuitesRestoreEveryRenderedArtifact(t *testing.T) {
	for _, suite := range []string{"tools/test-version-floor.sh", "tools/test-tag-binding.sh", "tools/test-r2-fallback.sh"} {
		t.Run(filepath.Base(suite), func(t *testing.T) {
			body := readRepoFile(t, suite)
			for _, comp := range floorComponents(t) {
				for _, artifact := range renderedArtifacts(t) {
					rel := comp + "/" + artifact
					if !strings.Contains(body, rel) {
						t.Errorf("%s re-renders the bootstraps but never names %s — a failed run leaves a TEST-keyed copy of it in the working tree", suite, rel)
					}
				}
			}
			// Partial artifacts (updater.install.sh: edge/gateway only) are
			// re-rendered by the SAME `sh tools/gen-bootstraps.sh` call these
			// suites make — it does not skip a component just because this
			// suite's restore list doesn't know about the file — so they need
			// the same per-owner coverage, component by component (never
			// cli/agent, which never had the file to begin with).
			for artifact, owners := range partialRenderedArtifacts(t) {
				for _, comp := range owners {
					rel := comp + "/" + artifact
					if !strings.Contains(body, rel) {
						t.Errorf("%s re-renders the bootstraps but never names %s — a failed run leaves a TEST-keyed copy of it in the working tree", suite, rel)
					}
				}
			}
		})
	}
}
