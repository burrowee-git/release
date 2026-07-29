package relconfig

import (
	"context"
	"os"
	"os/exec"
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
