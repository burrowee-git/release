// prefix_gate_test.go — the DIVERGENT-ONLY PREFIX rule and the normaliser it
// rests on.
//
// bin_dir_default_test.go already pins "an operator's own PREFIX is refused".
// This file pins the other half, which the blanket refusal did not have: a
// PREFIX that names the destination this installer would have picked anyway
// MISDIRECTS NOTHING, so it must be honoured — announced, cleared, and then
// forgotten — while everything else is still refused before a byte is placed.
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
// relay's reference implementation (relay main 6a2712e) and pinned here as
// TEXT rather than only exercised, because the one property that matters most
// is invisible on a bash host: `printf '%s'`, never `echo`.
//
// dash's echo (and bash's under xpg_echo) expands backslash escapes in its
// argument. An echo-based normaliser therefore reduces PREFIX='<bindir>\c' to
// '<bindir>' and ACCEPTS a prefix that names a completely different directory.
// TestInstallShRefusesOnlyAMisdirectingPrefix exercises exactly that shape, but
// it can only catch the regression on a host that has dash; this assertion
// catches it everywhere.
const normalizeDirBlock = "normalize_dir() {\n" +
	"    _nd=\"$(printf '%s' \"$1\" | sed -e 's|//*|/|g' -e 's|/*$||')\"\n" +
	"    printf '%s' \"${_nd:-/}\"\n" +
	"}"

// acceptanceLine is the exact announcement of an honoured PREFIX. Held once so
// the two tests that need it — the behavioural one and the source-text one
// below — cannot drift into asserting different things.
const acceptanceLine = `printf '%s\n' "install: PREFIX ('$PREFIX') names this installer's own destination ($_true_bin) — proceeding."`

// TestNormalizeDirIsPortedVerbatimAndPrintfBased pins the helper the gate's
// correctness rests on. Relay carries the same function in three scripts with a
// byte-identical drift guard over them; this repo's two root-only inner
// installers carry it too, and the same text has to appear in both — a fix
// applied to one copy and not the other is the failure class this rule was
// written for.
func TestNormalizeDirIsPortedVerbatimAndPrintfBased(t *testing.T) {
	src := string(mustRead(t, installShPath(t)))
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

// prefixShape is one PREFIX value under test, built from the sandbox home so
// every case names a path inside it.
type prefixShape struct {
	name  string
	build func(home string) string
}

// honouredPrefixes are the values that RESOLVE TO $BIN_DIR. Each is a spelling
// of the same directory, because normalize_dir's whole job is to see through
// the spellings core and an operator's shell actually produce.
var honouredPrefixes = []prefixShape{
	// Exactly what core injects: dirname($BIN_DIR).
	{"plain", func(home string) string { return filepath.Dir(binDir(home)) }},
	{"trailing-slash", func(home string) string { return filepath.Dir(binDir(home)) + "/" }},
	{"doubled-slash", func(home string) string { return filepath.Dir(binDir(home)) + "//" }},
}

// misdirectingPrefixes are the values that name some OTHER directory and must
// therefore be refused. The last two are not exotica: they are the two shapes a
// normaliser that "looked equivalent" would wrongly accept, and both truncate
// into an exact match with $BIN_DIR.
var misdirectingPrefixes = []prefixShape{
	// The operator's own per-user prefix — the original subject of the rule.
	{"a-different-directory", func(home string) string { return filepath.Join(home, ".local") }},
	// echo-expanded, '\c' means "stop output here": an echo-based normaliser
	// sees '<bindir>' and accepts. printf sees the literal backslash-c and the
	// comparison fails.
	{"backslash-c-truncation", func(home string) string { return binDir(home) + `\c` }},
	// A normaliser that stripped newlines (tr -d, head -1, an unquoted
	// expansion) would collapse '<parent>\n/bin' to '<parent>/bin' and accept.
	// sed on a printf'd string keeps the line break, so the comparison fails.
	{"embedded-newline", func(home string) string { return filepath.Dir(binDir(home)) + "\n" }},
	// The last two pin the "TEXTUAL ONLY" half of normalize_dir's contract,
	// which until now was a comment with nothing holding it: no '.'/'..'
	// folding, no symlink resolution, no path anchoring. A future "helpful"
	// normaliser (filepath.Clean semantics, realpath, readlink -f) would fold
	// '<parent>/./bin' back to '<parent>/bin' and ACCEPT — silently widening a
	// guard whose whole value is that it recognises exactly one thing.
	{"dot-suffix", func(home string) string { return filepath.Dir(binDir(home)) + "/." }},
	// Root is the degenerate input normalize_dir special-cases ('/' stays '/',
	// via the ${_nd:-/} default after sed eats every slash). It is still not
	// this destination, so it is still refused — a normaliser whose empty-result
	// branch collapsed to "" would compare equal against a $BIN_DIR that also
	// normalised to "".
	{"root", func(string) string { return "/" }},
}

// runInstallShWithPrefix runs install.sh under an explicit shell from a staged
// bundle, with PREFIX appended LAST so it wins over anything installShEnv set.
func runInstallShWithPrefix(t *testing.T, shell, home, staging, stub, prefix string) (string, error) {
	t.Helper()
	cmd := exec.Command(shell, installShPath(t))
	cmd.Dir = staging
	cmd.Env = append(installShEnv(home, stub), "PREFIX="+prefix)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// TestInstallShHonoursAPrefixNamingItsOwnDestination — the regression the
// blanket refusal was: a caller naming /usr/local (which is where the binaries
// were going anyway) got "nothing has been installed" and an exit 1.
//
// The install must COMPLETE, not merely exit 0: binaries in $BIN_DIR and a unit
// on disk, so a gate that "accepted" by falling through to a broken path would
// still fail here.
func TestInstallShHonoursAPrefixNamingItsOwnDestination(t *testing.T) {
	for _, shell := range shellsUnderTest(t) {
		for _, tc := range honouredPrefixes {
			t.Run(filepath.Base(shell)+"/"+tc.name, func(t *testing.T) {
				home := t.TempDir()
				stub := stubInitSystem(t)
				staging := t.TempDir()
				seedDummyBins(t, staging)
				// record_installed_version writes its $BIN_DIR copy only on a
				// host converged to the root scheme; the system config root is
				// what says so, and nothing else in this run creates it.
				if err := os.MkdirAll(sysConfigDir(home), 0o755); err != nil {
					t.Fatal(err)
				}
				prefix := tc.build(home)

				out, err := runInstallShWithPrefix(t, shell, home, staging, stub, prefix)
				if err != nil {
					t.Fatalf("install.sh refused PREFIX=%q, which resolves to its own destination %s: %v\n%s",
						prefix, binDir(home), err, out)
				}
				// The acceptance is ANNOUNCED. A silent accept would be the
				// same class of surprise as a silent redirect.
				assertContains(t, out, "names this installer's own destination", binDir(home))
				for _, b := range allBins {
					if _, statErr := os.Stat(filepath.Join(binDir(home), b)); statErr != nil {
						t.Errorf("%s not placed in %s under %s: %v", b, binDir(home), shell, statErr)
					}
				}
				if _, statErr := os.Stat(coreUnitPath(home)); statErr != nil {
					t.Errorf("no service unit at %s — the accepted run did not reach render_units: %v",
						coreUnitPath(home), statErr)
				}
			})
		}
	}
}

// TestInstallShSaysNothingAboutPrefixWhenNoneIsSet is the contrast that makes
// the assertion above mean something: the announcement must be conditional on a
// PREFIX actually being set, not printed on every install.
func TestInstallShSaysNothingAboutPrefixWhenNoneIsSet(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	if err := os.MkdirAll(sysConfigDir(home), 0o755); err != nil {
		t.Fatal(err)
	}

	out, err := runStaged(t, installShPath(t), staging, home, stub)
	if err != nil {
		t.Fatalf("default install failed: %v\n%s", err, out)
	}
	if strings.Contains(out, "names this installer's own destination") {
		t.Errorf("an install with no PREFIX set announced an accepted PREFIX:\n%s", out)
	}
}

// TestInstallShClearsAnAcceptedPrefix — accepted is not the same as inherited.
//
// The shared migration rungs read BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}"
// and the ladder is invoked with the `VAR=x sh run.sh` form, which ADDS to the
// environment rather than replacing it. Today install.sh also passes BIN_DIR
// explicitly, so a surviving PREFIX would change nothing — which is exactly why
// this is pinned as source text: the protection is one deleted assignment away
// from mattering, and by then no run would notice.
func TestInstallShClearsAnAcceptedPrefix(t *testing.T) {
	src := string(mustRead(t, installShPath(t)))
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

// TestInstallShRefusesOnlyAMisdirectingPrefix — the refusal, kept sharp. Every
// shape here names a directory that is NOT $BIN_DIR, so every one must fail,
// say so with both spellings of the real destination, and leave nothing behind:
// a refusal after a half-install is not a refusal.
func TestInstallShRefusesOnlyAMisdirectingPrefix(t *testing.T) {
	for _, shell := range shellsUnderTest(t) {
		for _, tc := range misdirectingPrefixes {
			t.Run(filepath.Base(shell)+"/"+tc.name, func(t *testing.T) {
				home := t.TempDir()
				stub := stubInitSystem(t)
				staging := t.TempDir()
				seedDummyBins(t, staging)
				prefix := tc.build(home)

				out, err := runInstallShWithPrefix(t, shell, home, staging, stub, prefix)
				if err == nil {
					t.Fatalf("install.sh honoured PREFIX=%q instead of refusing it — it does not resolve to %s:\n%s",
						prefix, binDir(home), out)
				}
				// Both spellings: the production literal an operator reads on a
				// real host, and the resolved destination this run would have
				// used.
				//
				// "is not it.)" is the TAIL of the second interpolating line,
				// and it is asserted for a reason the other strings cannot
				// cover: that line quotes $_prefix_bin, so under an echo
				// mutation a '\c' inside the offending value truncates it AND
				// swallows its own newline, gluing the hint line onto the
				// wreckage — while every other assertion here still matches,
				// because they are all satisfied by earlier lines. This is the
				// only string that becomes unreachable when that specific line
				// stops being printf.
				assertContains(t, out, "PREFIX", "0.2.0", wantBinDirDefault, binDir(home),
					"is not it.)", "nothing has been installed")
				// The prefix's own bin dir is checked only when it is inside the
				// sandbox: the "root" shape names /bin, and a suite that
				// stat()s real system paths would report on whatever the host
				// happens to have there rather than on this run.
				candidates := []string{binDir(home), devBinDir(home)}
				if strings.HasPrefix(prefix, home) {
					candidates = append(candidates, filepath.Join(prefix, "bin"))
				}
				for _, dir := range candidates {
					for _, b := range allBins {
						if _, statErr := os.Stat(filepath.Join(dir, b)); statErr == nil {
							t.Errorf("%s was placed in %s despite the refusal — the check ran too late to matter", b, dir)
						}
					}
				}
				if _, statErr := os.Stat(coreUnitPath(home)); statErr == nil {
					t.Errorf("a service unit was written despite the refusal:\n%s", out)
				}
			})
		}
	}
}
