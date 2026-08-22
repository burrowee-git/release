// bootstrap_prefix_test.go — what the outer bootstrap hands the inner
// installer as PREFIX, per component.
//
// The gateway and the edge install to /usr/local/bin, root-owned, and their
// inner installers REFUSE a PREFIX that would MISDIRECT the install rather than
// overriding it (inner/gateway/install.sh, inner/edge/install.sh); one that
// resolves to that same destination is honoured and then cleared.
// tools/bootstrap.template.sh is shared by cli, gateway, edge and agent, and it
// used to default PREFIX to $HOME/.local and pass it unconditionally — so every
// `curl … | sh` gateway install took the per-user branch, which also switched
// off unit rendering, migration and version recording. That is the defect these
// tests exist to keep out. Each root-only component joins this list in the same
// change that collapses its inner installer, or its bootstrap manufactures a
// PREFIX its installer will refuse and every `curl … | sh` fails.
//
// They RUN the rendered bootstraps' own code rather than matching text, because
// the branch is on $COMP at runtime: cli/install.sh and gateway/install.sh are
// byte-identical except for the baked knobs, so a static assertion cannot tell
// them apart. Same reasoning as trusted_comment_test.go's verifier tests, and
// the same funcBody helper.
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// publicComponents are the four components tools/bootstrap.template.sh serves.
// relay has its own template and no per-user prefix question.
var publicComponents = []string{"cli", "gateway", "edge", "agent"}

// rootOnly are the components whose inner installer has ONE destination
// (/usr/local/bin, root-owned) and refuses a PREFIX naming anywhere else. Their
// bootstrap must hand PREFIX through — never defaulted — and must not edit a
// shell rc.
var rootOnly = map[string]bool{"gateway": true, "edge": true}

// bakedComp reads the COMP="<name>" literal gen-bootstraps.sh substituted into
// a rendered bootstrap. The tests below bind the component from the file itself
// rather than from the loop variable, so a bootstrap rendered with the wrong
// COMP is exercised as the component it actually claims to be.
var bakedCompRe = regexp.MustCompile(`(?m)^COMP="([^"]+)"`)

func bakedComp(t *testing.T, rel string) string {
	t.Helper()
	m := bakedCompRe.FindStringSubmatch(readRepoFile(t, rel))
	if m == nil {
		t.Fatalf(`%s has no COMP="…" line`, rel)
	}
	return m[1]
}

// shellFunc lifts a complete function definition out of a rendered bootstrap,
// ready to be sourced. funcBody returns everything from the `name() {` header
// down to but not including the closing brace at column 0, so the brace is put
// back here.
func shellFunc(t *testing.T, rel, name string) string {
	t.Helper()
	return funcBody(t, readRepoFile(t, rel), name) + "\n}"
}

// runShellFragment runs script under /bin/sh in dir and returns its combined
// output, failing the test if it exits non-zero.
func runShellFragment(t *testing.T, dir, script string) string {
	t.Helper()
	cmd := exec.Command("sh", "-c", script)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "HOME="+dir)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("fragment failed: %v\n%s", err, out)
	}
	return string(out)
}

// TestRenderedBootstrapsResolvePrefixPerComponent is the first half: what
// resolve_prefix() answers when the operator set nothing, which is how
// essentially every install runs.
func TestRenderedBootstrapsResolvePrefixPerComponent(t *testing.T) {
	for _, comp := range publicComponents {
		t.Run(comp, func(t *testing.T) {
			rel := comp + "/install.sh"
			home := t.TempDir()

			got := runShellFragment(t, home, strings.Join([]string{
				"set -eu",
				"COMP=" + bakedComp(t, rel),
				shellFunc(t, rel, "resolve_prefix"),
				"resolve_prefix",
			}, "\n"))

			want := home + "/.local"
			if rootOnly[comp] {
				want = ""
			}
			if got != want {
				t.Errorf("%s resolves PREFIX=%q with none set, want %q — "+
					"the gateway must not manufacture one (its inner installer refuses it), "+
					"and the others must keep their per-user default", rel, got, want)
			}
		})
	}
}

// TestRenderedBootstrapsCanonicaliseTheExportedPrefix — one spelling leaves the
// bootstrap, whatever the operator typed.
//
// This became load-bearing when the root-only installers stopped refusing every
// set PREFIX: their gate NORMALISES before comparing, so `PREFIX=/usr/local/` is
// now an accepted, supported invocation instead of an abort — and everything
// downstream of that acceptance does plain string work. The migration runner
// derives BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}"; the stale-bin sweep
// decides "never sweep the install destination" by comparing directory NAMES.
// `/usr/local//bin` opens the same directory and matches neither name, and the
// sweep that stops recognising its own destination deletes the install it was
// protecting — reporting success.
//
// Collapsed here, the loose spelling never reaches any of them.
// (inner/_shared/migrations/upgrade.sh holds the second half of this, for the
// operator who runs the ladder by hand with no bootstrap in the picture.)
func TestRenderedBootstrapsCanonicaliseTheExportedPrefix(t *testing.T) {
	cases := []struct{ set, want string }{
		{"/opt/burrowee-explicit", "/opt/burrowee-explicit"}, // already canonical: untouched
		{"/usr/local/", "/usr/local"},                        // the shape core's injection and a shell's tab-completion produce
		{"/usr/local//", "/usr/local"},
		{"/opt//burrowee//x/", "/opt/burrowee/x"},
		{"/", "/"}, // root is a directory, not an empty string
	}
	for _, comp := range publicComponents {
		t.Run(comp, func(t *testing.T) {
			rel := comp + "/install.sh"
			baked := bakedComp(t, rel)
			for _, tc := range cases {
				home := t.TempDir()
				got := strings.TrimSpace(runShellFragment(t, home, strings.Join([]string{
					"set -eu",
					"COMP=" + baked,
					`PREFIX="` + tc.set + `"`,
					shellFunc(t, rel, "resolve_prefix"),
					"resolve_prefix",
				}, "\n")))
				if got != tc.want {
					t.Errorf("%s: resolve_prefix with PREFIX=%q gave %q, want %q — "+
						"a non-canonical prefix reaches the migration ladder as <prefix>//bin, "+
						"which the sweep's destination guard compares as text and does not recognise",
						rel, tc.set, got, tc.want)
				}
			}
		})
	}
}

// TestRenderedBootstrapsPassPrefixOnlyWhenSet is the half that actually decides
// what the inner installer sees, and it is not the same claim: resolving PREFIX
// to empty fixes nothing if the exec then passes `PREFIX=` anyway, because
// "set to empty" and "unset" are different questions to
// `[ -n "${PREFIX:-}" ]`.
//
// So this runs the real run_inner() against a stand-in inner installer that
// reports how PREFIX reached it, twice per component: with none set, and with
// one the operator set explicitly (which must still be passed, or the gateway's
// refusal could never fire and the override would be silent after all).
func TestRenderedBootstrapsPassPrefixOnlyWhenSet(t *testing.T) {
	const probe = `#!/bin/sh
if [ -n "${PREFIX+set}" ]; then echo "PREFIX=[$PREFIX]"; else echo "PREFIX-UNSET"; fi
`
	for _, comp := range publicComponents {
		t.Run(comp, func(t *testing.T) {
			rel := comp + "/install.sh"
			baked := bakedComp(t, rel)

			run := func(operatorPrefix string) string {
				home := t.TempDir()
				if err := os.MkdirAll(filepath.Join(home, "tmp", "x"), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(home, "tmp", "x", "install.sh"), []byte(probe), 0o755); err != nil {
					t.Fatal(err)
				}
				lines := []string{
					"set -eu",
					"COMP=" + baked,
					`TMP="` + filepath.Join(home, "tmp") + `"`,
					`TAG="` + baked + `/v0.2.0.2026.08.13.deadbeef"`,
				}
				if operatorPrefix != "" {
					lines = append(lines, `PREFIX="`+operatorPrefix+`"`)
				}
				lines = append(lines,
					shellFunc(t, rel, "resolve_prefix"),
					`PREFIX="$(resolve_prefix)"`,
					shellFunc(t, rel, "run_inner"),
					"run_inner",
				)
				return strings.TrimSpace(runShellFragment(t, home, strings.Join(lines, "\n")))
			}

			// (a) operator set nothing.
			got := run("")
			if rootOnly[comp] {
				if got != "PREFIX-UNSET" {
					t.Errorf("%s handed the inner installer %s with no PREFIX set; it must arrive UNSET, "+
						"or this component's root-only installer refuses an install nobody asked to redirect", rel, got)
				}
			} else if !strings.HasPrefix(got, "PREFIX=[") || strings.HasSuffix(got, "[]") {
				t.Errorf("%s handed the inner installer %s with no PREFIX set; it must still get the per-user default", rel, got)
			}

			// (b) operator set one explicitly — always forwarded, for every
			// component. For a root-only component that is what makes the
			// refusal reachable; a bootstrap that swallowed it would turn a
			// loud rejection into the silent override this whole change
			// rejects.
			if got, want := run("/opt/burrowee-explicit"), "PREFIX=[/opt/burrowee-explicit]"; got != want {
				t.Errorf("%s dropped an explicitly set PREFIX: got %s, want %s", rel, got, want)
			}
		})
	}
}

// TestRootOnlyBootstrapsWriteNoPathMarker: the PATH-persistence block appends
// `export PATH="$PREFIX/bin:$PATH"` to the operator's shell rc. For a root-only
// component $PREFIX is empty, so that block would write /bin — and it has
// nothing to do anyway, since /usr/local/bin is on every PATH already. Pinned as
// a text assertion on the guard itself: the block's body is a 30-line rc-file
// walk whose only observable output is a mutated $HOME, and this is the
// condition that stops it being entered at all.
func TestRootOnlyBootstrapsWriteNoPathMarker(t *testing.T) {
	const guard = `if [ "$COMP" != gateway ] && [ "$COMP" != edge ] && [ -z "${BURROWEE_UNINSTALL:-}" ]`
	for _, comp := range publicComponents {
		rel := comp + "/install.sh"
		if !strings.Contains(readRepoFile(t, rel), guard) {
			t.Errorf("%s does not guard its PATH-persistence block with %q — "+
				"a root-only component would append \"/bin\" to a shell rc", rel, guard)
		}
	}
}
