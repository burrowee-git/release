// prefix_gate_test.go — the DIVERGENT-ONLY PREFIX rule and the normaliser it
// rests on.
//
// root_only_test.go already pins "an operator's own PREFIX is refused". This
// file pins the other half, which the blanket refusal did not have: a PREFIX
// that names the destination this installer would have picked anyway MISDIRECTS
// NOTHING, so it must be honoured — announced, cleared, and then forgotten —
// while everything else is still refused before a byte is placed.
//
// Why that half is not cosmetic: core's updater injects
// PREFIX=<dirname²(ServeBin)> = /usr/local when it runs a component's scripts,
// and on 2026-08-22 relay's blanket refusal turned that into a fleet-wide
// "PREFIX is set to '/usr/local' … nothing has been updated". This installer
// escaped only because core also strips PREFIX for root-only components — i.e.
// the shipped installer was protected by a Go change on the other side of the
// exec, not by its own rule. These tests are that protection moved back where
// it belongs.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// normalizeDirBlock is install.sh's normalize_dir, verbatim — ported from
// relay's reference implementation (relay main 6a2712e) and pinned here as TEXT
// rather than only exercised, because the one property that matters most is
// invisible on a bash host: `printf '%s'`, never `echo`.
//
// dash's echo (and bash's under xpg_echo) expands backslash escapes in its
// argument. An echo-based normaliser therefore reduces PREFIX='<bindir>\c' to
// '<bindir>' and ACCEPTS a prefix that names a completely different directory.
// TestEdgeInstallRefusesOnlyAMisdirectingPrefix exercises exactly that shape,
// but it can only catch the regression on a host that has dash; this assertion
// catches it everywhere. The gateway's sibling pin
// (inner/gateway/install_test/prefix_gate_test.go) holds the same text —
// the two root-only inner installers carry one implementation between them and
// a fix applied to one copy only is the failure class this rule was written for.
const normalizeDirBlock = "normalize_dir() {\n" +
	"    _nd=\"$(printf '%s' \"$1\" | sed -e 's|//*|/|g' -e 's|/*$||')\"\n" +
	"    printf '%s' \"${_nd:-/}\"\n" +
	"}"

// acceptanceLine is the exact announcement of an honoured PREFIX. Held once so
// the behavioural test and the source-text test below cannot drift into
// asserting different things.
const acceptanceLine = `printf '%s\n' "install: PREFIX ('$PREFIX') names this installer's own destination ($_true_bin) — proceeding."`

// TestNormalizeDirIsPortedVerbatimAndPrintfBased pins the helper the gate's
// correctness rests on.
func TestNormalizeDirIsPortedVerbatimAndPrintfBased(t *testing.T) {
	src := readFile(t, installShPath(t))
	if !strings.Contains(src, normalizeDirBlock) {
		t.Errorf("install.sh's normalize_dir is not the ported reference implementation.\nwant it to contain:\n%s", normalizeDirBlock)
	}
	// Stated separately so the failure names the actual hazard rather than a
	// whitespace diff: an echo-based normaliser is not "a different spelling",
	// it silently accepts prefixes that misdirect the install.
	if strings.Contains(src, `_nd="$(echo `) {
		t.Error(`install.sh's normalize_dir uses echo — dash expands backslash escapes there, so ` +
			`PREFIX='<bindir>\c' would be normalised to '<bindir>' and ACCEPTED. Use printf instead.`)
	}
}

// prefixSandboxBinDir is the destination these tests redirect $BIN_DIR to.
//
// It is NOT the package's usual sandbox path (".../sysbin"): every honoured
// PREFIX is spelled "<parent>", and the installer compares "<parent>/bin"
// against $BIN_DIR, so a fixture whose bin dir is not literally named "bin"
// could never reach the accept branch at all — the test would pass by
// construction while proving nothing.
func prefixSandboxBinDir(sb sandbox) string { return filepath.Join(sb.home, "system", "bin") }

// prefixShape is one PREFIX value under test, built from the sandbox so every
// case names a path inside it.
type prefixShape struct {
	name  string
	build func(sb sandbox) string
}

// honouredPrefixes are the values that RESOLVE TO $BIN_DIR. Each is a spelling
// of the same directory, because normalize_dir's whole job is to see through
// the spellings core and an operator's shell actually produce.
var honouredPrefixes = []prefixShape{
	// Exactly what core injects: dirname($BIN_DIR).
	{"plain", func(sb sandbox) string { return filepath.Dir(prefixSandboxBinDir(sb)) }},
	{"trailing-slash", func(sb sandbox) string { return filepath.Dir(prefixSandboxBinDir(sb)) + "/" }},
	{"doubled-slash", func(sb sandbox) string { return filepath.Dir(prefixSandboxBinDir(sb)) + "//" }},
}

// misdirectingPrefixes are the values that name some OTHER directory and must
// therefore be refused. The last two are not exotica: they are the two shapes a
// normaliser that "looked equivalent" would wrongly accept, and both truncate
// into an exact match with $BIN_DIR.
var misdirectingPrefixes = []prefixShape{
	// The operator's own per-user prefix — the original subject of the rule.
	{"a-different-directory", func(sb sandbox) string { return filepath.Join(sb.home, ".local") }},
	// echo-expanded, '\c' means "stop output here": an echo-based normaliser
	// sees '<bindir>' and accepts. printf sees the literal backslash-c and the
	// comparison fails.
	{"backslash-c-truncation", func(sb sandbox) string { return prefixSandboxBinDir(sb) + `\c` }},
	// A normaliser that stripped newlines (tr -d, head -1, an unquoted
	// expansion) would collapse '<parent>\n/bin' to '<parent>/bin' and accept.
	// sed on a printf'd string keeps the line break, so the comparison fails.
	{"embedded-newline", func(sb sandbox) string { return filepath.Dir(prefixSandboxBinDir(sb)) + "\n" }},
}

// runWithPrefix runs the staged install.sh under an explicit shell with
// $BIN_DIR redirected to prefixSandboxBinDir and the given PREFIX set.
//
// The SYS_BIN_DIR entry is REPLACED rather than appended to: a duplicate key in
// an exec environment is resolved by libc, not by Go, so appending would leave
// which value the script sees up to the platform.
func runWithPrefix(t *testing.T, sb sandbox, shell, stub, prefix string, extra ...string) (string, error) {
	t.Helper()
	env := sb.env(stub, extra...)
	for i, kv := range env {
		if strings.HasPrefix(kv, "SYS_BIN_DIR=") {
			env[i] = "SYS_BIN_DIR=" + prefixSandboxBinDir(sb)
		}
	}
	env = append(env, "PREFIX="+prefix)
	cmd := exec.Command(shell, stagedInstaller(t, sb.staging))
	cmd.Dir = sb.staging
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// TestEdgeInstallHonoursAPrefixNamingItsOwnDestination — the regression the
// blanket refusal was: a caller naming /usr/local (which is where the binaries
// were going anyway) got "nothing has been installed" and an exit 1.
//
// The install must COMPLETE, not merely exit 0: binaries in $BIN_DIR and both
// units on disk, so a gate that "accepted" by falling through to a broken path
// would still fail here.
func TestEdgeInstallHonoursAPrefixNamingItsOwnDestination(t *testing.T) {
	for _, shell := range shellsUnderTest(t) {
		for _, tc := range honouredPrefixes {
			t.Run(filepath.Base(shell)+"/"+tc.name, func(t *testing.T) {
				sb := newSandbox(t)
				binDir := prefixSandboxBinDir(sb)
				prefix := tc.build(sb)

				out, err := runWithPrefix(t, sb, shell, stubRootEnv(t), prefix,
					"BURROWEE_VERSION=edge/v0.2.0.2026.08.14.abcdef12")
				if err != nil {
					t.Fatalf("install.sh refused PREFIX=%q, which resolves to its own destination %s: %v\n%s",
						prefix, binDir, err, out)
				}
				// The acceptance is ANNOUNCED. A silent accept would be the
				// same class of surprise as a silent redirect.
				assertContains(t, out, "names this installer's own destination", binDir)
				for _, b := range edgeBins {
					if _, statErr := os.Stat(filepath.Join(binDir, b)); statErr != nil {
						t.Errorf("%s not placed in %s under %s: %v", b, binDir, shell, statErr)
					}
				}
				for _, unit := range []string{"burrowee-edge.service", "burrowee-edge-updater.service"} {
					if _, statErr := os.Stat(filepath.Join(sb.unitDir, unit)); statErr != nil {
						t.Errorf("%s not rendered under %s — the accepted run stopped short: %v", unit, shell, statErr)
					}
				}
				assertContains(t, out, "edge system install complete")
			})
		}
	}
}

// TestEdgeInstallSaysNothingAboutPrefixWhenNoneIsSet is the contrast that makes
// the assertion above mean something: the announcement must be conditional on a
// PREFIX actually being set, not printed on every install.
func TestEdgeInstallSaysNothingAboutPrefixWhenNoneIsSet(t *testing.T) {
	sb := newSandbox(t)
	out, err := sb.run(t, "sh", stubRootEnv(t), "BURROWEE_VERSION=edge/v0.2.0.2026.08.14.abcdef12")
	if err != nil {
		t.Fatalf("default install failed: %v\n%s", err, out)
	}
	if strings.Contains(out, "names this installer's own destination") {
		t.Errorf("an install with no PREFIX set announced an accepted PREFIX:\n%s", out)
	}
}

// TestEdgeInstallClearsAnAcceptedPrefix — accepted is not the same as inherited.
//
// The shared migration rungs read BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}"
// and the ladder is invoked with the `VAR=x sh run.sh` form, which ADDS to the
// environment rather than replacing it. Today install.sh also passes BIN_DIR
// explicitly, so a surviving PREFIX would change nothing — which is exactly why
// this is pinned as source text: the protection is one deleted assignment away
// from mattering, and by then no run would notice.
func TestEdgeInstallClearsAnAcceptedPrefix(t *testing.T) {
	src := readFile(t, installShPath(t))
	i := strings.Index(src, acceptanceLine)
	if i < 0 {
		t.Fatalf("install.sh no longer carries the acceptance line — this test can no longer locate the branch")
	}
	rest := src[i:]
	end := strings.Index(rest, "\n    else")
	if end < 0 {
		t.Fatalf("the acceptance branch is not closed by an else — the gate changed shape")
	}
	if !strings.Contains(rest[:end], "unset PREFIX") {
		t.Errorf("the acceptance branch does not `unset PREFIX`; an accepted prefix would be inherited "+
			"by the migration ladder:\n%s", rest[:end])
	}
}

// TestEdgeInstallRefusesOnlyAMisdirectingPrefix — the refusal, kept sharp. Every
// shape here names a directory that is NOT $BIN_DIR, so every one must fail, say
// so with both spellings of the real destination, and leave nothing behind: a
// refusal after a half-install is not a refusal.
func TestEdgeInstallRefusesOnlyAMisdirectingPrefix(t *testing.T) {
	for _, shell := range shellsUnderTest(t) {
		for _, tc := range misdirectingPrefixes {
			t.Run(filepath.Base(shell)+"/"+tc.name, func(t *testing.T) {
				sb := newSandbox(t)
				binDir := prefixSandboxBinDir(sb)
				prefix := tc.build(sb)

				out, err := runWithPrefix(t, sb, shell, stubRootEnv(t), prefix)
				if err == nil {
					t.Fatalf("install.sh honoured PREFIX=%q instead of refusing it — it does not resolve to %s:\n%s",
						prefix, binDir, out)
				}
				// Both spellings: the production literal an operator reads on a
				// real host, and the resolved destination this run would have
				// used. A refusal truncated by an escape inside $PREFIX fails
				// here, which is what a plain `echo` of that line would do.
				assertContains(t, out, "PREFIX", collapseVersion, wantBinDirDefault, binDir, "nothing has been installed")
				for _, dir := range []string{binDir, filepath.Join(sb.home, ".local", "bin"), filepath.Join(prefix, "bin")} {
					for _, b := range edgeBins {
						if _, statErr := os.Stat(filepath.Join(dir, b)); statErr == nil {
							t.Errorf("%s was placed in %s despite the refusal — the check ran too late to matter", b, dir)
						}
					}
				}
				for _, unit := range []string{"burrowee-edge.service", "burrowee-edge-updater.service"} {
					if _, statErr := os.Stat(filepath.Join(sb.unitDir, unit)); statErr == nil {
						t.Errorf("%s was rendered despite the refusal:\n%s", unit, out)
					}
				}
			})
		}
	}
}
