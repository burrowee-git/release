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

// shellFiles is every *.sh in the tree, .git excluded.
func shellFiles(t *testing.T, root string) []string {
	t.Helper()
	var found []string
	err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == ".git" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(p, ".sh") {
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
