package relconfig

import (
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/burrowee-git/release-kit/build"
)

// WHICH BINARIES a component carries, stated twice and pinned here.
//
// It used to be stated three times with nothing comparing them: tools/build.sh's
// MAP (bin:pkg — what gets BUILT), tools/release.sh's bins_for (names — what the
// ZIP CARRIES), and this package's Bins (rkit's path, whose result is both built
// AND packaged). relconfig.go's doc comment said "mirroring tools/build.sh";
// nothing enforced it. The two shell copies are now one table in
// tools/binmap.sh, which both scripts read; this test pins the remaining Go copy
// to it by EXECUTING the real shell and comparing.
//
// Why not one copy: same constraint as tools/payload.sh. One side is bash on the
// operator's machine, the other is Go compiled into rkit, and neither can call
// the other during a cut without making the shell path depend on a binary it
// currently does not need.
//
// Why here and not in `rkit harness`: the harness already diffs both paths' real
// artifacts (cmd/rkit/harness.go), but needs a toolchain, four cross-compiles and
// a signing key, so nothing invokes it. This runs under a plain `go test ./...`.
//
// WHAT "AGREE" MEANS — established from the code, not assumed:
//
//  1. Component sets are equal: bin_components == Components. Both sides know the
//     five release components AND `burrowee`, the universal dispatcher.
//  2. Per component, {name → package} is equal. Package equality is real on this
//     axis because both sides hand the package to `go build`; a mismatch builds a
//     different program under the same filename.
//  3. bins_for names exactly the binaries bin_map builds — no more (built, signed,
//     silently unpackaged: the incident direction) and no fewer (fails closed on
//     the assembly `cp`).
//  4. `burrowee` is NOT a member of any release component's list on either side,
//     and bins_for is never called with it. The dispatcher is built once per
//     target from its own stamp and copied into every component zip by literal
//     name (release.sh build_dispatcher; rkit's second Bins("burrowee", …) +
//     dispArts). That asymmetry is the true shape — enforcing symmetry there
//     would break every cut.

// binmapSh is tools/binmap.sh, two levels up from internal/relconfig.
func binmapSh(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(root, "tools", "binmap.sh")
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("tools/binmap.sh not found: %v", err)
	}
	return p
}

// runBinmap sources tools/binmap.sh and runs one of its functions for real,
// under the same `set -euo pipefail` tools/build.sh and tools/release.sh set.
func runBinmap(t *testing.T, fn string, args ...string) string {
	t.Helper()
	argv := append([]string{"bash", binmapSh(t), fn}, args...)
	cmd := exec.Command("bash", append([]string{"-c",
		`set -euo pipefail; source "$1"; fn="$2"; shift 2; "${fn}" "$@"`}, argv...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%s %v: %v\n%s", fn, args, err, out)
	}
	return string(out)
}

// shellBinMap is tools/binmap.sh's bin_map for comp, as name → package.
func shellBinMap(t *testing.T, comp string) map[string]string {
	t.Helper()
	got := map[string]string{}
	for _, pair := range strings.Fields(runBinmap(t, "bin_map", comp)) {
		name, pkg, ok := strings.Cut(pair, ":")
		if !ok {
			t.Fatalf("bin_map %s: %q is not a bin:pkg pair", comp, pair)
		}
		if prev, dup := got[name]; dup {
			t.Fatalf("bin_map %s: %s listed twice (%s, %s)", comp, name, prev, pkg)
		}
		got[name] = pkg
	}
	return got
}

// pkgOf is the BinSpec → build.sh package-path normalisation. build.sh performs
// the exact inverse for relay's nested cli module: it cds to $SRC_DIR/cli and
// rewrites "./cli/cmd/x" to "./cmd/x", which is SubDir:"cli" + Package:"./cmd/x"
// written the other way round.
func pkgOf(b build.BinSpec) string {
	p := path.Join(b.SubDir, b.Package)
	if p == "." {
		return "."
	}
	return "./" + p
}

// goBinMap is relconfig.Bins for comp, as name → normalised package. The stamp
// and console identity are placeholders: this compares the binary/package
// manifest, not the ldflags (which legitimately differ per binary — relay bakes
// console identity into its cli and updater only — and are covered by
// relconfig_test.go).
func goBinMap(t *testing.T, comp string) map[string]string {
	t.Helper()
	bins, err := Bins(comp, "vSTAMP", "abc123", "wss://relay-api.burrowee.com", "")
	if err != nil {
		t.Fatalf("Bins(%s): %v", comp, err)
	}
	got := map[string]string{}
	for _, b := range bins {
		if prev, dup := got[b.Name]; dup {
			t.Fatalf("Bins(%s): %s listed twice (%s, %s)", comp, b.Name, prev, pkgOf(b))
		}
		got[b.Name] = pkgOf(b)
	}
	return got
}

// TestBinMapComponentsMatchRelconfigComponents closes the set direction: a
// component added to one side only never reaches the per-component comparison
// below, because that comparison iterates a list this test proves is shared.
func TestBinMapComponentsMatchRelconfigComponents(t *testing.T) {
	shell := strings.Fields(runBinmap(t, "bin_components"))
	if !reflect.DeepEqual(shell, Components) {
		t.Fatalf("component sets disagree:\n  tools/binmap.sh: %v\n  relconfig:       %v", shell, Components)
	}
}

// TestBinMapsAgree is the cross-check: for every component, the shell table and
// relconfig.Bins name the same binaries built from the same packages.
func TestBinMapsAgree(t *testing.T) {
	for _, comp := range Components {
		t.Run(comp, func(t *testing.T) {
			shell := shellBinMap(t, comp)
			goSide := goBinMap(t, comp)
			if !reflect.DeepEqual(shell, goSide) {
				t.Errorf("build lists disagree for %s:\n  tools/binmap.sh:   %v\n  relconfig.Bins:    %v",
					comp, shell, goSide)
			}
		})
	}
}

// TestBinsForCarriesExactlyWhatBinMapBuilds pins the third statement of the
// fact — what the ZIP CARRIES — to the first. A binary built but not packaged is
// signed, notarized and silently missing from the payload; the reverse fails
// closed on the assembly `cp`. Only one of those two is survivable, which is why
// the packaged list is derived rather than restated.
func TestBinsForCarriesExactlyWhatBinMapBuilds(t *testing.T) {
	for _, comp := range Components {
		t.Run(comp, func(t *testing.T) {
			var built []string
			for name := range shellBinMap(t, comp) {
				built = append(built, name)
			}
			sort.Strings(built)
			packaged := strings.Fields(runBinmap(t, "bins_for", comp))
			sort.Strings(packaged)
			if !reflect.DeepEqual(packaged, built) {
				t.Errorf("%s: bins_for (packaged) %v != bin_map (built) %v", comp, packaged, built)
			}
		})
	}
}

// TestDispatcherIsNeverAReleaseComponentBinary states the one asymmetry that is
// real, so a later reader does not "fix" it: `burrowee` is a build target on both
// sides, but never a member of a release component's list. Each component zip
// gets the dispatcher from its own separately-stamped build, copied in by literal
// name (tools/release.sh build_dispatcher; cmd/rkit/build.go's second
// Bins("burrowee", …) into dispArts).
func TestDispatcherIsNeverAReleaseComponentBinary(t *testing.T) {
	if got := goBinMap(t, "burrowee"); !reflect.DeepEqual(got, map[string]string{"burrowee": "."}) {
		t.Fatalf("dispatcher bins = %v, want the single repo-root binary", got)
	}
	for _, comp := range Components {
		if comp == "burrowee" {
			continue
		}
		if pkg, found := shellBinMap(t, comp)[comp]; found {
			t.Errorf("%s lists the dispatcher `burrowee` as one of its own binaries (%s)", comp, pkg)
		}
		if _, found := goBinMap(t, comp)["burrowee"]; found {
			t.Errorf("relconfig.Bins(%s) lists the dispatcher `burrowee` as one of its own binaries", comp)
		}
	}
}

// TestBinMapRejectsAnUnknownComponent — the validation tools/build.sh's `*)` arm
// used to do, now the shared table's. A cut that cannot resolve its own binary
// list must stop, not build an empty one.
func TestBinMapRejectsAnUnknownComponent(t *testing.T) {
	cmd := exec.Command("bash", "-c",
		`set -euo pipefail; source "$1"; bin_map "$2"`, "bash", binmapSh(t), "console")
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("bin_map console succeeded, output %q — an unknown component must fail closed", out)
	}
	if !strings.Contains(string(out), "unknown component: console") {
		t.Errorf("bin_map console stderr = %q, want it to name the unknown component", out)
	}
}
