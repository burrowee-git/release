package main

import (
	"os"
	"testing"
)

// TestRunHarnessLiveCLI runs the full oracle-vs-candidate harness for the cli
// component: it shells out to the real tools/release.sh --dry-run, needs a
// TEST minisign key on disk, and reads the real component source worktrees
// (or their BURROWEE_SRC_*/BB overrides). It never runs by default — Task 6
// is where this goes live; the comparePayloads unit tests in diff_test.go
// are this task's real coverage. Set RELEASE_HARNESS_LIVE=1 and
// RELEASE_REPO_DIR to opt in.
func TestRunHarnessLiveCLI(t *testing.T) {
	if os.Getenv("RELEASE_HARNESS_LIVE") != "1" {
		t.Skip("set RELEASE_HARNESS_LIVE=1 (and RELEASE_REPO_DIR) to run the live oracle-vs-candidate harness — see Task 6")
	}
	repo := os.Getenv("RELEASE_REPO_DIR")
	if repo == "" {
		t.Fatal("RELEASE_HARNESS_LIVE=1 requires RELEASE_REPO_DIR to point at a burrowee release worktree")
	}
	if err := runHarness([]string{"--component", "cli", "--repo", repo}); err != nil {
		t.Fatal(err)
	}
}
