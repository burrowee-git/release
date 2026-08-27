package relconfig

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestBurroweeScheme(t *testing.T) {
	// version.Scheme signature is (semver, sha, dateUTC). Burrowee's stamp
	// format is v<semver>.<date>.<sha>.
	got := BurroweeScheme("1.4.2", "a1b2c3d4", "2026.07.13")
	want := "v1.4.2.2026.07.13.a1b2c3d4"
	if got != want {
		t.Fatalf("BurroweeScheme = %q, want %q", got, want)
	}
}

func TestBurroweeBetaScheme(t *testing.T) {
	// Same shape as BurroweeScheme with a ".beta." segment inserted between
	// the semver and the date.
	got := BurroweeBetaScheme("1.4.2", "a1b2c3d4", "2026.07.13")
	want := "v1.4.2.beta.2026.07.13.a1b2c3d4"
	if got != want {
		t.Fatalf("BurroweeBetaScheme = %q, want %q", got, want)
	}
}

func TestStampMatchesVersionSh(t *testing.T) {
	// Repo-local integration check. Skips unless RELEASE_REPO_DIR points at a
	// burrowee release worktree (set by the harness / CI).
	repo := os.Getenv("RELEASE_REPO_DIR")
	if repo == "" {
		t.Skip("set RELEASE_REPO_DIR to the burrowee release worktree to run")
	}
	ctx := context.Background()
	semverFile := filepath.Join(repo, "versions", "cli")
	got, err := Stamp(ctx, semverFile, repo, "stable")
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.CommandContext(ctx, "bash", filepath.Join(repo, "tools", "version.sh"),
		"cli", "--stamp")
	// version.sh --stamp needs SRC_DIR in env.
	cmd.Env = append(os.Environ(), "SRC_DIR="+repo)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("version.sh: %v", err)
	}
	want := strings.TrimSpace(string(out))
	if got != want {
		t.Fatalf("Stamp=%q version.sh=%q — if only sha/date derivation differs, "+
			"switch Stamp to computeDirect and note the release-kit gap", got, want)
	}
}

// TestStampMatchesVersionShBeta is TestStampMatchesVersionSh's beta-channel
// twin: it proves relconfig.Stamp(..., "beta") and `version.sh --channel beta
// --stamp` cannot drift, same as the stable pair does. versions/cli.beta is
// optional (its presence is the open-beta-cycle flag — see tools/version.sh's
// header comment) and is not committed in every worktree, so this builds an
// isolated fixture repo — a copy of tools/version.sh plus a synthetic
// versions/cli.beta — the same pattern tools/version.test.sh uses, rather
// than depending on a real open beta cycle existing.
func TestStampMatchesVersionShBeta(t *testing.T) {
	repo := os.Getenv("RELEASE_REPO_DIR")
	if repo == "" {
		t.Skip("set RELEASE_REPO_DIR to the burrowee release worktree to run")
	}
	ctx := context.Background()

	fixture := t.TempDir()
	versionsDir := filepath.Join(fixture, "versions")
	toolsDir := filepath.Join(fixture, "tools")
	if err := os.MkdirAll(versionsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(toolsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	versionSh, err := os.ReadFile(filepath.Join(repo, "tools", "version.sh"))
	if err != nil {
		t.Fatal(err)
	}
	fixtureVersionSh := filepath.Join(toolsDir, "version.sh")
	if err := os.WriteFile(fixtureVersionSh, versionSh, 0o755); err != nil {
		t.Fatal(err)
	}
	semverFile := filepath.Join(versionsDir, "cli.beta")
	if err := os.WriteFile(semverFile, []byte("0.3.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := Stamp(ctx, semverFile, repo, "beta")
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.CommandContext(ctx, "bash", fixtureVersionSh, "cli", "--channel", "beta", "--stamp")
	// version.sh --stamp needs SRC_DIR in env; SRC_DIR points at the real repo
	// so the sha8 matches what Stamp derives above.
	cmd.Env = append(os.Environ(), "SRC_DIR="+repo)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("version.sh: %v", err)
	}
	want := strings.TrimSpace(string(out))
	if got != want {
		t.Fatalf("Stamp(beta)=%q version.sh=%q", got, want)
	}
}
