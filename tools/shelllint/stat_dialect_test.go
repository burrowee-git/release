// Package shelllint holds repo-wide checks over the shell this project ships
// and runs. It has no production code: the thing under test is every *.sh in the
// tree, so there is nothing for it to sit beside.
//
// It exists because the GNU/BSD `stat` chain was written twice, independently,
// in two files — inner/gateway/install.sh (shipped, and it stranded a production
// node) and tools/test-e2e-relay.sh (a harness that would have blamed the
// relay installer for its own portability bug). Fixing two instances does
// nothing about the third, and the shape is easy to reach for and reads as
// obviously-portable to anyone who has only ever run it on macOS.
package shelllint

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// repoRoot is the working tree root, resolved from this test's own location
// (tools/shelllint/) and then proved rather than assumed.
func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "go.mod")); err != nil {
		t.Fatalf("no go.mod at %s — this test is scanning the wrong tree: %v", root, err)
	}
	return root
}

// shellFiles is every shell script in the SOURCE tree — .git, and the build
// output under dist/, excluded.
//
// *.command counts too: tools/cut.command is bash and is opened by
// LaunchServices, so the extension is load-bearing and cannot be .sh. Matching
// on .sh alone would have left the one script that launches a cut as the only
// shell in the repo this lint never read.
//
// dist/ is not source: it holds the staged payloads of past cuts, each carrying
// the install.sh that shipped in it. Those copies are immutable history, and one
// of them legitimately contains the very defect this lint exists to prevent
// (the bug shipped, was found on a node, and was fixed here). Walking them makes
// the lint fail on any machine that has ever cut a release — including, always,
// immediately after a cut, since a cut writes dist/ before this test next runs.
// A lint that fires on its own build output is a lint that gets disabled.
func shellFiles(t *testing.T, root string) []string {
	t.Helper()
	var found []string
	err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == ".git" || d.Name() == "dist" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(p, ".sh") || strings.HasSuffix(p, ".command") {
			found = append(found, p)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", root, err)
	}
	if len(found) < 10 {
		t.Fatalf("only found %d shell files under %s — the walk is broken and this test would pass vacuously", len(found), root)
	}
	return found
}

// TestNoShellTriesTheBsdStatFormatBeforeTheGnuOne forbids exactly one shape:
// `stat -f … || stat -c …` on a single line.
//
// That shape looks like a portable fallback and is not one. On GNU coreutils
// `-f` is --file-system, so the first branch does not fail cleanly — it reads
// the format string as a second path, prints the filesystem geometry of the real
// path to STDOUT, and exits 1. The `||` then appends the correct answer to that
// dump, and the caller compares a multi-line blob against the value it wanted.
// The reverse order is safe (BSD stat rejects `-c` with a usage error and no
// stdout) and is deliberately still allowed, as is a probe-once helper.
//
// One precise shape, not a clever shell parser: a lint that tries to reason
// about reachability will either miss the next instance or cry wolf, and either
// way stops being trusted.
func TestNoShellTriesTheBsdStatFormatBeforeTheGnuOne(t *testing.T) {
	root := repoRoot(t)
	for _, path := range shellFiles(t, root) {
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		for n, line := range strings.Split(string(body), "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "#") {
				continue // prose about the bug is how the bug stays fixed
			}
			f := strings.Index(line, "stat -f")
			if f < 0 {
				continue
			}
			c := strings.Index(line, "stat -c")
			if c < 0 || c < f {
				continue
			}
			rel, _ := filepath.Rel(root, path)
			t.Errorf("%s:%d tries the BSD stat format before the GNU one:\n\t%s\n"+
				"On Linux `stat -f FMT PATH` reads FMT as a second path, dumps PATH's filesystem\n"+
				"geometry to stdout and exits 1, so the `||` fallback appends the real answer to a\n"+
				"blob. Probe the dialect once (see inner/gateway/install.sh), or put `-c` first and\n"+
				"gate each branch on its own exit status.", rel, n+1, strings.TrimSpace(line))
		}
	}
}

// TestShellFilesCoversDotCommand pins the glob widening that brought
// tools/cut.command under this lint. Without it the widening is invisible: both
// lints pass either way today, because cut.command happens to be clean — so a
// revert to `.sh`-only would go unnoticed until the one script that launches a
// release drifted, unread.
func TestShellFilesCoversDotCommand(t *testing.T) {
	root := repoRoot(t)
	var found bool
	for _, p := range shellFiles(t, root) {
		if strings.HasSuffix(p, "tools/cut.command") {
			found = true
		}
	}
	if !found {
		t.Error("shellFiles must include tools/cut.command — it is bash, and .command is load-bearing (LaunchServices opens it)")
	}
}
