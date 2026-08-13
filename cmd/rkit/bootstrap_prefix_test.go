// bootstrap_prefix_test.go — what the outer bootstrap hands the inner
// installer as PREFIX, per component.
//
// The gateway installs to /usr/local/bin, root-owned, and its inner installer
// REFUSES a set PREFIX rather than overriding it (inner/gateway/install.sh).
// tools/bootstrap.template.sh is shared by cli, gateway, edge and agent, and it
// used to default PREFIX to $HOME/.local and pass it unconditionally — so every
// `curl … | sh` gateway install took the per-user branch, which also switched
// off unit rendering, migration and version recording. That is the defect these
// tests exist to keep out.
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
			if comp == "gateway" {
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
			if comp == "gateway" {
				if got != "PREFIX-UNSET" {
					t.Errorf("%s handed the inner installer %s with no PREFIX set; it must arrive UNSET, "+
						"or the gateway's root-only installer refuses an install nobody asked to redirect", rel, got)
				}
			} else if !strings.HasPrefix(got, "PREFIX=[") || strings.HasSuffix(got, "[]") {
				t.Errorf("%s handed the inner installer %s with no PREFIX set; it must still get the per-user default", rel, got)
			}

			// (b) operator set one explicitly — always forwarded, for every
			// component. For the gateway that is what makes the refusal
			// reachable; a bootstrap that swallowed it would turn a loud
			// rejection into the silent override this whole change rejects.
			if got, want := run("/opt/burrowee-explicit"), "PREFIX=[/opt/burrowee-explicit]"; got != want {
				t.Errorf("%s dropped an explicitly set PREFIX: got %s, want %s", rel, got, want)
			}
		})
	}
}

// TestGatewayBootstrapWritesNoPathMarker: the PATH-persistence block appends
// `export PATH="$PREFIX/bin:$PATH"` to the operator's shell rc. For the gateway
// $PREFIX is empty, so that block would write /bin — and it has nothing to do
// anyway, since /usr/local/bin is on every PATH already. Pinned as a text
// assertion on the guard itself: the block's body is a 30-line rc-file walk
// whose only observable output is a mutated $HOME, and this is the condition
// that stops it being entered at all.
func TestGatewayBootstrapWritesNoPathMarker(t *testing.T) {
	const guard = `if [ "$COMP" != gateway ] && [ -z "${BURROWEE_UNINSTALL:-}" ]`
	for _, comp := range publicComponents {
		rel := comp + "/install.sh"
		if !strings.Contains(readRepoFile(t, rel), guard) {
			t.Errorf("%s does not guard its PATH-persistence block with %q — "+
				"the gateway would append \"/bin\" to a shell rc", rel, guard)
		}
	}
}
