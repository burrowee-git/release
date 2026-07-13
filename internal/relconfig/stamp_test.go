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

func TestStampMatchesVersionSh(t *testing.T) {
	// Repo-local integration check. Skips unless RELEASE_REPO_DIR points at a
	// burrowee release worktree (set by the harness / CI).
	repo := os.Getenv("RELEASE_REPO_DIR")
	if repo == "" {
		t.Skip("set RELEASE_REPO_DIR to the burrowee release worktree to run")
	}
	ctx := context.Background()
	semverFile := filepath.Join(repo, "versions", "cli")
	got, err := Stamp(ctx, semverFile, repo)
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
