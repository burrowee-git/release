// exec_redirect_test.go — a second repo-wide shell shape, for the same reason
// as stat_dialect_test.go: it was written independently in three installers
// (cli, edge, gateway), it reads as obviously-guarded to anyone who has only
// run it on macOS, and it shipped.
package shelllint

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestNoShellGuardsAnExecRedirectWithABraceGroup forbids exactly one shape:
// `exec` with a redirection inside a `{ …; }` brace group.
//
// It looks like a guarded probe and is not one. dash — /bin/sh on every
// Debian-family host — treats a FAILED `exec` redirection as fatal and exits
// the script, status 2. A brace group is not a subshell, so it does not contain
// that exit; neither `2>/dev/null` nor a trailing `|| true` survives it, both of
// which were tried:
//
//	$ dash -c 'set -eu; { exec 4</nonexistent; } 2>/dev/null || true; echo unreachable'
//	$ echo $?
//	2
//
// The shape cost the cli and edge installers every non-interactive install on
// Debian-family hosts — CI, a console push, `curl … | sh` under a supervisor —
// each of which installed in full and then reported failure with no message,
// because the probe sat at the very end of the script.
//
// The fix, in all three installers: probe in a SUBSHELL, which does contain the
// exit, then do the real `exec` in the parent once the answer is known.
//
// One precise shape, not a clever shell parser: a lint that tries to reason
// about reachability will either miss the next instance or cry wolf, and either
// way stops being trusted. A bare `exec N<>…` outside braces is deliberately
// still allowed — that is the real open, and by then the subshell has already
// proved it succeeds.
func TestNoShellGuardsAnExecRedirectWithABraceGroup(t *testing.T) {
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
			b := strings.Index(line, "{ exec ")
			if b < 0 {
				continue
			}
			rest := line[b+len("{ exec "):]
			if !strings.ContainsAny(rest, "<>") {
				continue // `{ exec cmd; }` replaces the shell; no redirection to fail
			}
			rel, _ := filepath.Rel(root, path)
			t.Errorf("%s:%d guards an `exec` redirection with a brace group:\n\t%s\n"+
				"dash exits the whole script (status 2) when an `exec` redirection fails, and a\n"+
				"brace group is not a subshell, so `2>/dev/null` and `|| true` both leak it. Probe\n"+
				"in a subshell — `( exec 3<>/dev/tty ) 2>/dev/null` — then `exec` for real (see\n"+
				"inner/gateway/install.sh).", rel, n+1, strings.TrimSpace(line))
		}
	}
}
