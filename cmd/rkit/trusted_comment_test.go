package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/burrowee-git/release/internal/relconfig"
)

// THE MINISIGN TRUSTED COMMENT, written twice and verified a third time — all
// three pinned to each other here, under a plain `go test ./...`.
//
// The trusted comment is the only version-bearing field the outer bootstrap can
// verify: the zip names and SHA256SUMS.txt are version-independent, so binding
// the verified BYTES to the requested TAG is done entirely by comparing this
// string. It is written by cmd/rkit/build.go (rkit's cut path) and by
// tools/release.sh (the operator's), and reconstructed by
// tools/bootstrap.template.sh, which hard-fails the install on a mismatch.
//
// Why this duplication outranked the payload/binmap ones it follows: a
// writer/verifier drift is invisible to tests and review and is discovered by
// every user's install failing — after the release is signed, notarized and
// published. Unlike a missing payload member it cannot be quietly re-cut; the
// artifact is already in people's hands and the installer refuses it.
//
// WHY THE VERIFIER IS NOT COLLAPSED INTO THE WRITERS. It could have been made a
// third caller of tools/trustcomment.sh at render time — but it must not be,
// for two independent reasons:
//
//  1. A verifier handed the writer's answer verifies nothing. The bootstrap's
//     job is to bind bytes to the tag IT resolved, from ITS own inputs (a
//     $COMP baked at render, a $TAG resolved at install). Deriving `expect`
//     from the writer would make a buggy writer produce a matching expectation
//     and the check would pass — precisely the class of failure being closed.
//  2. It is not possible anyway. Only $COMP is known at render time; the stamp
//     is not, so at most a prefix could be baked and the rest would still be
//     reconstructed. And the shipped installer is a standalone POSIX-sh script
//     curl'd to a stranger's machine, which runs months later against releases
//     cut by a LATER tools/release.sh. There is no moment at which the two
//     could share code — the trust boundary between them is real.
//
// So the agreement is PINNED, not collapsed: the tests below lift the real
// `expect=` line out of the template and execute it, per component, against the
// real writers — including the `${TAG#*/}` transformation, which is the part
// with an actual chance of being wrong.

// signedStamps are the stamp shapes a release is cut with: a normal published
// stamp, a two-digit minor, and a stamp whose semver contains the component's
// own name (nothing escapes or splits on it, but that is worth failing on
// rather than assuming).
var signedStamps = []string{
	"v0.1.65.2026.07.23.55e631a5",
	"v0.2.0.2026.08.07.695a4423",
	"v10.20.30.2026.12.31.deadbeef",
}

// signedComponents is every component whose SHA256SUMS.txt gets a trusted
// comment — relconfig's list minus the `burrowee` dispatcher, which is a build
// target that rides inside other components' zips and is never signed or
// published on its own. Derived rather than restated so a new component is
// cross-checked the day it is added.
func signedComponents(t *testing.T) []string {
	t.Helper()
	var out []string
	for _, c := range relconfig.Components {
		if c == "burrowee" {
			continue
		}
		out = append(out, c)
	}
	if len(out) < 5 {
		t.Fatalf("only %d signed components (%v) — relconfig.Components looks wrong", len(out), out)
	}
	return out
}

// repoRoot is the working tree root, two levels up from cmd/rkit.
func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return root
}

// readRepoFile reads a repo-relative file, failing the test if it is missing —
// a moved script must not turn a cross-check into a silent skip.
func readRepoFile(t *testing.T, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(repoRoot(t), rel))
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	return string(b)
}

// shellTrustedComment sources tools/trustcomment.sh and runs the real
// trusted_comment, under the same `set -euo pipefail` tools/release.sh sets.
func shellTrustedComment(t *testing.T, comp, stamp string) string {
	t.Helper()
	cmd := exec.Command("bash", "-c",
		`set -euo pipefail; source "$1"; trusted_comment "$2" "$3"`,
		"bash", filepath.Join(repoRoot(t), "tools", "trustcomment.sh"), comp, stamp)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("trusted_comment %s %s: %v\n%s", comp, stamp, err, out)
	}
	return string(out)
}

// expectLineRe matches the bootstrap's reconstruction of the trusted comment.
var expectLineRe = regexp.MustCompile(`(?m)^expect=.*$`)

// verifierLine is the one `expect=…` line in a bootstrap template — the
// verifier's whole construction, lifted verbatim so that editing the template
// changes what this test executes.
func verifierLine(t *testing.T, rel string) string {
	t.Helper()
	hits := expectLineRe.FindAllString(readRepoFile(t, rel), -1)
	if len(hits) != 1 {
		t.Fatalf("%s has %d `expect=` lines, want exactly 1: %q", rel, len(hits), hits)
	}
	return hits[0]
}

// runVerifierLine executes the lifted `expect=` line in POSIX sh with the two
// inputs the shipped installer has at that point — $COMP (baked at render) and
// $TAG (resolved at install) — and returns what it built.
func runVerifierLine(t *testing.T, line, comp, tag string) string {
	t.Helper()
	script := "set -eu\nCOMP=\"$1\"\nTAG=\"$2\"\n" + line + "\nprintf '%s' \"$expect\"\n"
	out, err := exec.Command("sh", "-c", script, "sh", comp, tag).CombinedOutput()
	if err != nil {
		t.Fatalf("verifier line %q with COMP=%s TAG=%s: %v\n%s", line, comp, tag, err, out)
	}
	return string(out)
}

// TestTrustedCommentFormatIsFrozen is the "nothing published changes" gate.
// Every signature already in the wild carries one of these strings, and the
// installers already on people's machines compare against exactly this shape.
// Literals, not a re-derivation: a test that recomputes the format cannot
// notice the format moving.
func TestTrustedCommentFormatIsFrozen(t *testing.T) {
	const stamp = "v0.1.65.2026.07.23.55e631a5"
	frozen := map[string]string{
		"cli":     "burrowee cli v0.1.65.2026.07.23.55e631a5",
		"gateway": "burrowee gateway v0.1.65.2026.07.23.55e631a5",
		"edge":    "burrowee edge v0.1.65.2026.07.23.55e631a5",
		"agent":   "burrowee agent v0.1.65.2026.07.23.55e631a5",
		"relay":   "burrowee relay v0.1.65.2026.07.23.55e631a5",
	}
	comps := signedComponents(t)
	if len(frozen) != len(comps) {
		t.Fatalf("frozen table covers %d components, %v needs %d — a new component's string must be frozen too",
			len(frozen), comps, len(comps))
	}
	for _, comp := range comps {
		want, ok := frozen[comp]
		if !ok {
			t.Fatalf("no frozen string for component %q", comp)
		}
		if got := trustedComment(comp, stamp); got != want {
			t.Errorf("trustedComment(%q, %q) = %q, want %q — this string is embedded in signatures already published",
				comp, stamp, got, want)
		}
	}
}

// TestShellWriterMatchesGoWriter pins tools/trustcomment.sh to build.go by
// executing the real shell, for every component and stamp shape. These are the
// two hands that sign: rkit's cut path and the operator's.
func TestShellWriterMatchesGoWriter(t *testing.T) {
	for _, comp := range signedComponents(t) {
		for _, stamp := range signedStamps {
			t.Run(comp+"/"+stamp, func(t *testing.T) {
				want := trustedComment(comp, stamp)
				if got := shellTrustedComment(t, comp, stamp); got != want {
					t.Errorf("writers disagree for %s %s:\n  tools/trustcomment.sh: %q\n  build.go:              %q",
						comp, stamp, got, want)
				}
			})
		}
	}
}

// TestShellWriterFailsClosedOnAnEmptyStamp — the shell writer's arguments come
// from variables that a refactor can leave unset, and `-t "burrowee cli "`
// signs fine and then fails every install's version binding. That must abort
// the cut instead, before anything is signed.
func TestShellWriterFailsClosedOnAnEmptyStamp(t *testing.T) {
	for _, args := range [][]string{{"cli", ""}, {"", "v1.0.0"}, {"cli"}, {}} {
		argv := append([]string{"bash", "-c",
			`set -euo pipefail; source "$1"; shift; trusted_comment "$@"`,
			"bash", filepath.Join(repoRoot(t), "tools", "trustcomment.sh")}, args...)
		out, err := exec.Command(argv[0], argv[1:]...).CombinedOutput()
		if err == nil {
			t.Errorf("trusted_comment %q succeeded with output %q — an incomplete comment must fail closed", args, out)
		}
	}
}

// joinContinuations folds `\`-continued shell lines into one, so a test can
// look at a whole command rather than at whichever fragment a `-t` landed on.
func joinContinuations(src string) []string {
	var out []string
	var cur string
	for _, line := range strings.Split(src, "\n") {
		cur += strings.TrimSuffix(line, "\\")
		if strings.HasSuffix(line, "\\") {
			continue
		}
		out = append(out, cur)
		cur = ""
	}
	return out
}

// TestReleaseShellSignsOnlyWithTheSharedHelper closes the direction the helper
// alone cannot: a helper nobody calls fixes nothing. Every `minisign -S` in
// tools/release.sh must sign with the value the helper produced, and no line
// may open-code a `-t "burrowee …"` again — which is exactly what the three
// sites did before, two of them hardcoding `relay` where a `${comp}` was
// already in scope.
func TestReleaseShellSignsOnlyWithTheSharedHelper(t *testing.T) {
	src := readRepoFile(t, "tools/release.sh")

	signSites, helperCalls := 0, 0
	for _, line := range joinContinuations(src) {
		if strings.Contains(line, "minisign -S") {
			signSites++
			if !strings.Contains(line, `-t "${tcomment}"`) {
				t.Errorf("a minisign signing site does not use the shared trusted comment:\n  %s", strings.TrimSpace(line))
			}
		}
		if strings.Contains(line, `tcomment="$(trusted_comment "${comp}" "${stamp}")"`) {
			helperCalls++
		}
	}

	// Three sites today: do_release (the four public components), do_release_relay
	// and distribute_relay. The floor keeps the scan from passing vacuously if the
	// signing command is ever renamed out from under it.
	if signSites < 3 {
		t.Fatalf("found %d `minisign -S` sites in tools/release.sh, want at least 3 — the scan is no longer finding them", signSites)
	}
	if helperCalls != signSites {
		t.Errorf("%d signing sites but %d `trusted_comment \"${comp}\" \"${stamp}\"` call sites — one of them derives its comment some other way",
			signSites, helperCalls)
	}
	if i := strings.Index(src, `-t "burrowee`); i >= 0 {
		t.Errorf("tools/release.sh open-codes a trusted comment again at offset %d: %q",
			i, strings.TrimSpace(src[i:i+min(60, len(src)-i)]))
	}
}

// funcBody returns the body of a top-level `name() {` function in a shell
// script — up to the closing brace in column 0. Nested functions (indented)
// are part of the body and do not terminate it.
func funcBody(t *testing.T, src, name string) string {
	t.Helper()
	start := strings.Index(src, "\n"+name+"() {\n")
	if start < 0 {
		t.Fatalf("no top-level function %s() in the script", name)
	}
	rest := src[start+1:]
	end := strings.Index(rest, "\n}\n")
	if end < 0 {
		t.Fatalf("function %s() is never closed at column 0", name)
	}
	return rest[:end]
}

// TestRelayCutSitesResolveComponentRelay is the byte-identity proof for the two
// sites that used to hardcode `relay`. They now pass `${comp}`, which is the
// same string ONLY because both functions are relay-only and bind comp=relay
// once, near the top. That was the reason for the hardcode and it is not a
// format difference — relay is the private, gated component, but its comment
// has always been `burrowee relay <stamp>`. Asserting the binding here is what
// makes "nothing published changes" true rather than believed.
func TestRelayCutSitesResolveComponentRelay(t *testing.T) {
	src := readRepoFile(t, "tools/release.sh")
	assign := regexp.MustCompile(`(?m)^\s*(?:local\s+[^\n]*?\b)?comp=(\S+)`)
	for _, fn := range []string{"distribute_relay", "do_release_relay"} {
		t.Run(fn, func(t *testing.T) {
			body := funcBody(t, src, fn)
			hits := assign.FindAllStringSubmatch(body, -1)
			if len(hits) != 1 {
				t.Fatalf("%s() assigns comp %d times (%v); the trusted comment's `${comp}` is only provably `relay` while it is bound exactly once",
					fn, len(hits), hits)
			}
			if hits[0][1] != "relay" {
				t.Fatalf("%s() binds comp=%s, want relay — its signature's trusted comment would change component", fn, hits[0][1])
			}
		})
	}
}

// TestBootstrapVerifierAgreesWithTheWriters is the one that matters: it runs
// the SHIPPED verifier's own construction against the writers, for every
// component the public template serves and every stamp shape — including the
// `${TAG#*/}` step, where the tag the installer resolved becomes the stamp the
// release was signed with. A disagreement here is an install-time outage for
// everyone, discovered only after publication.
func TestBootstrapVerifierAgreesWithTheWriters(t *testing.T) {
	line := verifierLine(t, "tools/bootstrap.template.sh")
	for _, comp := range []string{"cli", "gateway", "edge", "agent"} {
		for _, stamp := range signedStamps {
			t.Run(comp+"/"+stamp, func(t *testing.T) {
				tag := comp + "/" + stamp // what the bootstrap resolves, and what release.sh tags
				want := trustedComment(comp, stamp)
				if got := runVerifierLine(t, line, comp, tag); got != want {
					t.Errorf("the shipped verifier and the writers disagree for tag %s:\n  bootstrap expects: %q\n  releases are signed: %q",
						tag, got, want)
				}
			})
		}
	}
}

// TestGeneratedBootstrapsCarryTheTemplateVerifier — the template is not what
// ships; <comp>/install.sh is, and it is served from the static channel exactly
// as committed. tools/gen-bootstraps.sh substitutes only @COMP@/@PUBKEY@/
// @PREFLIGHT_SHA256@/@MIN_VERSION@, none of which appear in the `expect=` line,
// so the generated line must be byte-identical to the template's — and the
// baked $COMP it reads must be the component whose directory it sits in, or the
// verifier is comparing against a different component's releases.
func TestGeneratedBootstrapsCarryTheTemplateVerifier(t *testing.T) {
	line := verifierLine(t, "tools/bootstrap.template.sh")
	if strings.Contains(line, "@") {
		t.Fatalf("the verifier line %q now carries a render placeholder; this test must render instead of comparing", line)
	}
	for _, comp := range []string{"cli", "gateway", "edge", "agent"} {
		t.Run(comp, func(t *testing.T) {
			rel := comp + "/install.sh"
			if got := verifierLine(t, rel); got != line {
				t.Errorf("%s is out of step with the template (re-run tools/gen-bootstraps.sh):\n  published: %q\n  template:  %q", rel, got, line)
			}
			want := fmt.Sprintf("COMP=%q", comp)
			if !strings.Contains(readRepoFile(t, rel), want) {
				t.Errorf("%s does not bake %s — its version binding would compare against another component's releases", rel, want)
			}
		})
	}
}

// TestRelayBootstrapDoesNoVersionBinding records the one gap, so it is a known
// shape rather than an oversight: relay's gated channel serves stamp-less
// latest.<os>-<arch>.zip names, so its installer has no tag to bind and does
// only the signature + checksum checks. Relay's trusted comment is therefore
// WRITTEN (by both writers, pinned above) but VERIFIED by nobody.
//
// If that binding is added — it should be — this test goes red, and the fix is
// to add relay to TestBootstrapVerifierAgreesWithTheWriters rather than to
// delete this.
func TestRelayBootstrapDoesNoVersionBinding(t *testing.T) {
	if expectLineRe.MatchString(readRepoFile(t, "tools/relay-bootstrap.template.sh")) {
		t.Error("relay's bootstrap now reconstructs a trusted comment — cross-check it against the writers in TestBootstrapVerifierAgreesWithTheWriters")
	}
}
