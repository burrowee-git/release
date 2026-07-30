package relconfig

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The updater binary must carry the core/updater pin, and every OTHER binary
// must keep the component stamp. Shipping the stamp on the updater is what made
// a node's reported updater version permanently unequal to the catalog's.
func TestBinsStampsUpdaterWithPinNotStamp(t *testing.T) {
	const stamp, pin = "v0.1.99.2026.07.28.d4dc509d", "v0.1.12"
	got, err := Bins("edge", stamp, "abc123", "", pin)
	if err != nil {
		t.Fatalf("Bins: %v", err)
	}
	var sawUpdater bool
	for _, b := range got {
		want := "-X main.version=" + stamp
		if strings.HasSuffix(b.Name, "-updater") {
			sawUpdater = true
			want = "-X main.version=" + pin
		}
		if !strings.Contains(b.Ldflags, want) {
			t.Errorf("%s: ldflags %q missing %q", b.Name, b.Ldflags, want)
		}
	}
	if !sawUpdater {
		t.Fatal("edge produced no *-updater binary — test asserts nothing")
	}
}

// edge bakes consolePubHexProd alongside the version; pinning must REPLACE the
// version term, never rebuild the flag string, or that identity is silently lost.
func TestUpdaterPinPreservesComponentLdflags(t *testing.T) {
	got, err := Bins("edge", "vSTAMP", "abc123", "", "v0.1.12")
	if err != nil {
		t.Fatalf("Bins: %v", err)
	}
	for _, b := range got {
		if strings.HasSuffix(b.Name, "-updater") {
			if !strings.Contains(b.Ldflags, "abc123") {
				t.Fatalf("%s: consolePubHex dropped by pinning: %q", b.Name, b.Ldflags)
			}
		}
	}
}

// An empty pin (agent, which has no core/updater dependency) leaves every
// binary on the component stamp — matching build.sh, which excludes agent.
func TestEmptyPinLeavesStamp(t *testing.T) {
	got, err := Bins("cli", "vSTAMP", "", "", "")
	if err != nil {
		t.Fatalf("Bins: %v", err)
	}
	for _, b := range got {
		if !strings.Contains(b.Ldflags, "-X main.version=vSTAMP") {
			t.Errorf("%s: ldflags %q lost the stamp", b.Name, b.Ldflags)
		}
	}
}

// TestUpdaterPinMatchesBashHelper pins the MIRROR itself, not just each side
// separately: relconfig.UpdaterPin (rkit's produce path) and
// tools/updater_pin.sh (release.sh→build.sh's produce path) must emit the
// IDENTICAL stamp for the same real core/updater pin, or the two produce paths
// disagree and the divergence lands in the console's updater_version — exactly
// the "console offers an update that can never converge" failure this file
// exists to prevent. Repo-local integration check, same shell-out-and-diff
// pattern as TestStampMatchesVersionSh in stamp_test.go: skips unless
// RELEASE_REPO_DIR (this release worktree, for tools/updater_pin.sh) and
// EDGE_SRC (the edge main worktree, for a real core/updater pin) are both set.
func TestUpdaterPinMatchesBashHelper(t *testing.T) {
	repo := os.Getenv("RELEASE_REPO_DIR")
	if repo == "" {
		t.Skip("set RELEASE_REPO_DIR to the burrowee release worktree to run")
	}
	edgeSrc := os.Getenv("EDGE_SRC")
	if edgeSrc == "" {
		t.Skip("set EDGE_SRC to the edge main worktree (a real core/updater pin) to run")
	}
	ctx := context.Background()

	got, err := UpdaterPin(ctx, "/opt/homebrew/bin/go", edgeSrc)
	if err != nil {
		t.Fatalf("UpdaterPin: %v", err)
	}
	if got == "" {
		t.Fatal("UpdaterPin returned an empty pin against a real edge worktree — asserts nothing")
	}

	// bash -c 'script' $0 $1 ... — $0 below is the updater_pin.sh path, so the
	// script body can `source "$0"` without hand-quoting it into the command
	// string (a repo path containing spaces would otherwise break sourcing).
	cmd := exec.CommandContext(ctx, "bash", "-c", `set -euo pipefail; source "$0"; updater_pin .`,
		repo+"/tools/updater_pin.sh")
	cmd.Dir = edgeSrc
	cmd.Env = append(os.Environ(), "GO_BIN=/opt/homebrew/bin/go")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("tools/updater_pin.sh: %v", err)
	}
	want := strings.TrimSpace(string(out))

	if got != want {
		t.Fatalf("produce paths disagree: relconfig.UpdaterPin=%q tools/updater_pin.sh=%q — an rkit cut and a release.sh cut would stamp the same pin two different ways", got, want)
	}
}

// stubGo writes a fake `go` executable to a temp dir that answers `list -m`
// with version and `mod download -json` with a .info file holding infoJSON —
// mirroring tools/test-updater-pin.sh's stub_info() so the exact same fixture
// JSON can pin both sides of the bash/Go mirror.
func stubGo(t *testing.T, version, infoJSON string) string {
	t.Helper()
	dir := t.TempDir()
	infoPath := filepath.Join(dir, "v.info")
	if err := os.WriteFile(infoPath, []byte(infoJSON), 0o644); err != nil {
		t.Fatalf("write .info fixture: %v", err)
	}
	goPath := filepath.Join(dir, "go")
	script := "#!/usr/bin/env bash\n" +
		"if [ \"$1\" = \"mod\" ] && [ \"$2\" = \"download\" ]; then\n" +
		"    printf '{\\n\\t\"Path\": \"github.com/burrowee-git/core/updater\",\\n\\t\"Info\": \"" + infoPath + "\"\\n}\\n'\n" +
		"    exit 0\n" +
		"fi\n" +
		"if [ \"$1\" = \"list\" ]; then printf '" + version + "'; exit 0; fi\n" +
		"exit 0\n"
	if err := os.WriteFile(goPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write stub go: %v", err)
	}
	return goPath
}

// TestUpdaterPinRejectsHashWithTrailingGarbage pins divergence row 1 from the
// bash/Go equivalence review: hexHash used to be unanchored at the end and
// ACCEPTED an Origin.Hash with trailing garbage after a valid-looking hash
// prefix (e.g. "65d86769XYZ"), while tools/updater_pin.sh's sed extraction —
// which demands a literal quote immediately after the captured hex run —
// rejects it outright. Anchoring hexHash at both ends (see its doc comment)
// closes this gap.
func TestUpdaterPinRejectsHashWithTrailingGarbage(t *testing.T) {
	goPath := stubGo(t, "v0.1.12", `{"Version":"v0.1.12","Time":"2026-07-26T21:25:11Z","Origin":{"Hash":"65d86769XYZ"}}`)
	_, err := UpdaterPin(context.Background(), goPath, t.TempDir())
	if err == nil {
		t.Fatal("UpdaterPin accepted an Origin.Hash with trailing non-hex garbage — must reject, matching tools/updater_pin.sh's sed extraction")
	}
}

// TestUpdaterPinAcceptsBareDate pins divergence row 2: tools/updater_pin.sh
// accepts a Time value that is a bare "YYYY-MM-DD" with no time-of-day (its
// sed extraction only needs the date prefix to match), but an earlier version
// of this package rejected it because it parsed Time as time.Time, which
// requires full RFC3339. Reading Time as a raw string and prefix-matching it
// with dateFromTime (instead of type-parsing) fixes this.
func TestUpdaterPinAcceptsBareDate(t *testing.T) {
	goPath := stubGo(t, "v0.1.12", `{"Version":"v0.1.12","Time":"2026-07-26","Origin":{"Hash":"65d86769b2ccd42ecf5814702ca6a8d66c375b0c"}}`)
	got, err := UpdaterPin(context.Background(), goPath, t.TempDir())
	if err != nil {
		t.Fatalf("UpdaterPin rejected a bare YYYY-MM-DD Time value that tools/updater_pin.sh accepts: %v", err)
	}
	want := "v0.1.12.2026.07.26.65d86769"
	if got != want {
		t.Fatalf("UpdaterPin = %q, want %q", got, want)
	}
}

// TestUpdaterPinUsesLiteralDatePrefixNotUTC pins divergence row 3 — the
// silent two-string divergence this whole feature exists to prevent:
// tools/updater_pin.sh takes the LITERAL leading "YYYY-MM-DD" from the Time
// string, so a non-UTC offset does not shift the date. An earlier version of
// this package called .UTC() on a parsed time.Time, which for
// "2026-07-27T01:00:00+05:00" (UTC is one calendar day earlier) silently
// produced "2026.07.26" instead of bash's "2026.07.27" — two different
// stamps for the identical pin.
func TestUpdaterPinUsesLiteralDatePrefixNotUTC(t *testing.T) {
	goPath := stubGo(t, "v0.1.12", `{"Version":"v0.1.12","Time":"2026-07-27T01:00:00+05:00","Origin":{"Hash":"65d86769b2ccd42ecf5814702ca6a8d66c375b0c"}}`)
	got, err := UpdaterPin(context.Background(), goPath, t.TempDir())
	if err != nil {
		t.Fatalf("UpdaterPin: %v", err)
	}
	want := "v0.1.12.2026.07.27.65d86769"
	if got != want {
		t.Fatalf("UpdaterPin = %q, want %q (literal date prefix, not UTC-shifted)", got, want)
	}
}
