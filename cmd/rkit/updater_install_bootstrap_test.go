package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// THE UPDATER RECOVERY BOOTSTRAP — <comp>/updater.install.sh, the THIRD @MODE@
// rendered from the SAME tools/bootstrap.template.sh as <comp>/install.sh and
// <comp>/upgrade.sh (see upgrade_bootstrap_test.go for the two-mode original).
//
// It resolves + verifies + unzips a release exactly as install.sh does, then
// hands off to the inner updater.install.sh instead of the inner install.sh —
// the narrow recovery tool that reinstalls only the updater (binary + unit) on
// a host that already has the component, for when the updater itself is stale,
// stopped, or was never installed.
//
// Rendered for edge and gateway ONLY (tools/gen-bootstraps.sh's
// UPDATER_INSTALL_COMPONENTS): those are the two components with a supervised
// updater SERVICE to recover. cli's updater is a one-shot binary with no
// service (inner/cli/install.sh writes no unit and never elevates), and agent
// has no updater installer at all — writing updater.install.sh for either would
// advertise a URL for functionality that does not exist.

// updaterInstallComponents is the fixed set updater.install.sh is rendered
// for — named explicitly here, the same way tools/gen-bootstraps.sh's
// UPDATER_INSTALL_COMPONENTS names it, rather than inferred from whichever
// components a loop happens to reach.
var updaterInstallComponents = []string{"edge", "gateway"}

// updaterInstallConsumers discovers which top-level component directories hold
// an updater.install.sh — discovered, not restated, so a component that gains
// or loses the file is noticed rather than silently accepted.
func updaterInstallConsumers(t *testing.T) []string {
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
		if _, err := os.Stat(filepath.Join(root, e.Name(), "updater.install.sh")); err == nil {
			comps = append(comps, e.Name())
		}
	}
	sort.Strings(comps)
	return comps
}

// TestUpdaterInstallBootstrapsAreExactlyEdgeAndGateway closes the set in both
// directions: cli and agent must NOT get one (cli's updater has no service to
// recover; agent has no updater installer at all), and edge and gateway both
// must.
func TestUpdaterInstallBootstrapsAreExactlyEdgeAndGateway(t *testing.T) {
	want := append([]string(nil), updaterInstallComponents...)
	sort.Strings(want)
	got := updaterInstallConsumers(t)
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("directories with an updater.install.sh %v, want exactly %v (re-run tools/gen-bootstraps.sh)", got, want)
	}
}

// TestUpdaterInstallBootstrapBakesTheSameTrustAnchorsAsInstall is the whole
// point of the shared template: the two renders differ in MODE (and therefore
// which inner script runs) and in nothing the trust chain depends on. A drift
// here is not cosmetic — an updater.install.sh with a stale pubkey fails every
// signature check, one with a stale preflight pin fails every preflight, and
// one with a stale floor refuses every resolved tag.
func TestUpdaterInstallBootstrapBakesTheSameTrustAnchorsAsInstall(t *testing.T) {
	for _, comp := range updaterInstallComponents {
		t.Run(comp, func(t *testing.T) {
			install, updaterInstall := comp+"/install.sh", comp+"/updater.install.sh"
			for _, name := range []string{"PUBKEY", "MIN_VERSION", "PREFLIGHT_SHA256"} {
				want := bakedAssignment(t, install, name)
				if got := bakedAssignment(t, updaterInstall, name); got != want {
					t.Errorf("%s bakes %s=%q but %s bakes %q — the two renders must agree (re-run tools/gen-bootstraps.sh and commit BOTH)", updaterInstall, name, got, install, want)
				}
			}
			// And the preflight pin is not merely EQUAL to install.sh's, it is
			// the real digest: two renders agreeing on a wrong value is exactly
			// the failure an equality-only check cannot see.
			if got, want := bakedAssignment(t, updaterInstall, "PREFLIGHT_SHA256"), digestOf(t, comp+"/preflight.sh"); got != want {
				t.Errorf("%s pins %s, which is not %s/preflight.sh's digest %s", updaterInstall, got, comp, want)
			}
		})
	}
}

// TestUpdaterInstallBakedModeIsRealAndDistinct — the mode split is what makes
// this file different from install.sh/upgrade.sh, so it must render its own
// distinct value, not fall through to one of theirs (an unsubstituted @MODE@,
// or a value that collides with "install", would run the WRONG inner script).
func TestUpdaterInstallBakedModeIsRealAndDistinct(t *testing.T) {
	for _, comp := range updaterInstallComponents {
		t.Run(comp, func(t *testing.T) {
			if got := bakedAssignment(t, comp+"/updater.install.sh", "MODE"); got != "updater.install" {
				t.Errorf("%s/updater.install.sh bakes MODE=%q, want \"updater.install\"", comp, got)
			}
		})
	}
}

// modeDependentLineIndices returns the (0-based) line indices in
// tools/bootstrap.template.sh where the literal @MODE@ placeholder appears —
// the ONLY source of textual variation between two renders of the same
// component under different modes, since @COMP@, @PUBKEY@, @PREFLIGHT_SHA256@
// and @MIN_VERSION@ are baked identically for every mode of one component.
func modeDependentLineIndices(t *testing.T) map[int]bool {
	t.Helper()
	lines := strings.Split(readRepoFile(t, "tools/bootstrap.template.sh"), "\n")
	idx := map[int]bool{}
	for i, line := range lines {
		if strings.Contains(line, "@MODE@") {
			idx[i] = true
		}
	}
	if len(idx) == 0 {
		t.Fatal("tools/bootstrap.template.sh has no @MODE@ placeholder at all — the mode substitution this test pins no longer exists")
	}
	return idx
}

// TestUpdaterInstallBootstrapDiffersFromInstallOnlyAtModeLines proves the
// "byte-identical within a template family except for the mode-dependent
// lines" shape the whole @MODE@ design rests on. Every line that differs
// between a component's install.sh and its updater.install.sh must be a line
// where tools/bootstrap.template.sh actually placed an @MODE@ — never a line
// that is supposed to be fixed (PUBKEY, MIN_VERSION, PREFLIGHT_SHA256, or any
// of the shared verification logic).
func TestUpdaterInstallBootstrapDiffersFromInstallOnlyAtModeLines(t *testing.T) {
	modeLines := modeDependentLineIndices(t)
	for _, comp := range updaterInstallComponents {
		t.Run(comp, func(t *testing.T) {
			installLines := strings.Split(readRepoFile(t, comp+"/install.sh"), "\n")
			updaterLines := strings.Split(readRepoFile(t, comp+"/updater.install.sh"), "\n")
			if len(installLines) != len(updaterLines) {
				t.Fatalf("%s/install.sh has %d lines, %s/updater.install.sh has %d — a pure @MODE@ substitution cannot change the line count", comp, len(installLines), comp, len(updaterLines))
			}
			differed := 0
			for i := range installLines {
				if installLines[i] == updaterLines[i] {
					continue
				}
				differed++
				if !modeLines[i] {
					t.Errorf("line %d differs between %s/install.sh and %s/updater.install.sh, but tools/bootstrap.template.sh line %d has no @MODE@ placeholder — something other than the mode changed:\n  install.sh:          %q\n  updater.install.sh:  %q",
						i+1, comp, comp, i+1, installLines[i], updaterLines[i])
				}
			}
			if differed == 0 {
				t.Fatalf("%s/install.sh and %s/updater.install.sh are byte-identical — @MODE@ was not substituted", comp, comp)
			}
		})
	}
}

// modeDispatchRe lifts the shipped mode-guard + inner-script resolution out of
// a committed bootstrap. The markers exist for exactly this: keep them stable.
var modeDispatchRe = regexp.MustCompile(`(?ms)^# BEGIN mode-dispatch\b.*?^# END mode-dispatch$`)

// shippedModeDispatchBlock returns the mode-dispatch block of a committed
// bootstrap, failing if the markers are gone — a renamed marker must break
// this test loudly, not turn it into a silent skip.
func shippedModeDispatchBlock(t *testing.T, rel string) string {
	t.Helper()
	block := modeDispatchRe.FindString(readRepoFile(t, rel))
	if block == "" {
		t.Fatalf("%s has no BEGIN/END mode-dispatch block — this test can no longer execute the shipped inner-script resolution", rel)
	}
	if !strings.Contains(block, "INNER=") {
		t.Fatalf("%s's mode-dispatch block does not set INNER", rel)
	}
	return block
}

// runModeDispatch executes the lifted mode-dispatch block with MODE=mode set,
// exactly as the rendered bootstrap sets it from its own baked assignment, and
// reports the resulting $INNER (or the failure).
func runModeDispatch(t *testing.T, block, mode string) (inner string, err error, stderr string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "dispatch.sh")
	if werr := os.WriteFile(path, []byte(block), 0o600); werr != nil {
		t.Fatal(werr)
	}
	const runner = `set -eu
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
MODE="$2"
. "$1"
printf '%s' "$INNER"
`
	cmd := exec.Command("sh", "-c", runner, "sh", path, mode)
	var stdout, stderrBuf bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderrBuf
	runErr := cmd.Run()
	return stdout.String(), runErr, stderrBuf.String()
}

// TestModeDispatchResolvesTheInnerScript is the RED-PROOF this whole file
// exists for: it drives the shipped dispatch logic directly and asserts which
// inner script each mode resolves to. A generator or template bug that maps
// "updater.install" to the wrong inner script — including quietly falling back
// to "install.sh" — reddens here, not just in a byte-identity check that
// cannot see WHICH script a line names.
func TestModeDispatchResolvesTheInnerScript(t *testing.T) {
	// The block is identical across every component and mode (it switches only
	// on the runtime $MODE, never on $COMP), so any rendered file carries it —
	// edge/updater.install.sh is as good a source as any.
	block := shippedModeDispatchBlock(t, "edge/updater.install.sh")
	cases := []struct{ mode, wantInner string }{
		{"install", "install.sh"},
		{"upgrade", "install.sh"},
		{"updater.install", "updater.install.sh"},
	}
	for _, c := range cases {
		t.Run(c.mode, func(t *testing.T) {
			inner, err, stderr := runModeDispatch(t, block, c.mode)
			if err != nil {
				t.Fatalf("mode %q: dispatch block failed: %v (%s)", c.mode, err, stderr)
			}
			if inner != c.wantInner {
				t.Errorf("mode %q resolved INNER=%q, want %q", c.mode, inner, c.wantInner)
			}
		})
	}
}

// TestModeDispatchRejectsAnUnbakedMode is the negative control: an
// unsubstituted or unrecognised mode must fail closed rather than silently
// defaulting to install.sh's inner script.
func TestModeDispatchRejectsAnUnbakedMode(t *testing.T) {
	block := shippedModeDispatchBlock(t, "edge/updater.install.sh")
	for _, bad := range []string{"", "@MODE@", "bogus", "Install", "updater"} {
		t.Run(bad, func(t *testing.T) {
			inner, err, _ := runModeDispatch(t, block, bad)
			if err == nil {
				t.Errorf("mode %q was accepted and resolved INNER=%q — an unbaked/unknown mode must fail closed", bad, inner)
			}
		})
	}
}
