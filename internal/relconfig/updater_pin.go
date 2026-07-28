package relconfig

// updater_pin.go — the updater binary's version is the core/updater MODULE PIN,
// not the component stamp. Mirrors tools/build.sh's updater_pin() contract so
// the two produce paths (release.sh→build.sh and rkit) agree.
//
// WHY THIS EXISTS AT ALL: rkit had no updater stamping, so every rkit cut baked
// the component stamp into `burrowee-<comp>-updater`. A node then reports its
// component version as its updater version, which can never equal the catalog's
// updater_version (the pin) — so the console offers an updater update forever
// and the two-phase push runs a phase that cannot converge. Shipped that way in
// edge v0.1.99.

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strings"

	"github.com/burrowee-git/release-kit/build"
)

// cleanTag matches a release tag and nothing else: no pseudo-versions, no
// pre-release or build suffixes. A pin that is not a clean tag means someone is
// building against a branch or a replace, which must never reach a cut.
var cleanTag = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)

// UpdaterPin resolves the github.com/burrowee-git/core/updater version pinned by
// the module in modDir, rejecting anything but a clean tag. For relay the caller
// passes the NESTED cli module dir, which is where its updater lives.
//
// Returns ("", nil) when the module has no core/updater dependency at all — the
// agent's case. Callers keep the component stamp for those binaries, matching
// build.sh, which excludes agent from pin resolution for the same reason.
// goBin is the go toolchain to shell out to. Spec leaves it unset (release-kit
// resolves "go" from PATH the same way), so callers pass "go".
func UpdaterPin(ctx context.Context, goBin, modDir string) (string, error) {
	if goBin == "" {
		goBin = "go"
	}
	cmd := exec.CommandContext(ctx, goBin, "list", "-m", "-f", "{{.Version}}", "github.com/burrowee-git/core/updater")
	cmd.Dir = modDir
	out, err := cmd.Output()
	if err != nil {
		// `go list -m` writes its diagnosis to stderr. A module that simply is
		// not a dependency of this one is not an error — the agent has no
		// core/updater, and rkit's scratch fixtures have none either; those keep
		// the component stamp, exactly as release.sh skips agent at its caller.
		//
		// Every OTHER failure is returned. Swallowing them is precisely the
		// defect this file exists to prevent: a silent fallback to the component
		// stamp is what shipped a mis-stamped updater in the first place.
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			stderr := string(ee.Stderr)
			if strings.Contains(stderr, "not a known dependency") ||
				strings.Contains(stderr, "no required module") ||
				strings.Contains(stderr, "not in the module graph") {
				return "", nil
			}
			return "", fmt.Errorf("relconfig: resolve core/updater pin in %s: %w: %s", modDir, err, strings.TrimSpace(stderr))
		}
		return "", fmt.Errorf("relconfig: resolve core/updater pin in %s: %w", modDir, err)
	}
	v := strings.TrimSpace(string(out))
	if v == "" {
		return "", nil
	}
	if !cleanTag.MatchString(v) {
		return "", fmt.Errorf("relconfig: core/updater pinned to %q in %s — repin to a clean tag before cutting", v, modDir)
	}
	return v, nil
}

// applyUpdaterPin rewrites the version ldflag to updaterVersion for every
// *-updater binary in bins, leaving every other binary and every other flag
// untouched.
//
// It REPLACES the version term rather than rebuilding the flag string, because
// a binary's ldflags can carry component-specific terms alongside the version
// (edge's consolePubHexProd, relay's console identity) and rebuilding wholesale
// silently drops them — a bug already caught once in review on the build.sh side.
//
// It FAILS CLOSED: if the version term is not found to replace, that is an
// error, not a silent no-op. build.sh's equivalent was a bash substitution that
// quietly did nothing when its pattern missed, which is how a mis-stamped
// updater shipped while the build log claimed the right version.
func applyUpdaterPin(bins []build.BinSpec, stamp, updaterVersion string) error {
	if updaterVersion == "" {
		return nil // nothing pinned (agent) — component stamp stands, as build.sh does
	}
	want := "-X main.version=" + stamp
	repl := "-X main.version=" + updaterVersion
	for i := range bins {
		if !strings.HasSuffix(bins[i].Name, "-updater") {
			continue
		}
		if !strings.Contains(bins[i].Ldflags, want) {
			return fmt.Errorf("relconfig: %s: cannot pin updater version — ldflags %q has no %q to replace", bins[i].Name, bins[i].Ldflags, want)
		}
		bins[i].Ldflags = strings.Replace(bins[i].Ldflags, want, repl, 1)
	}
	return nil
}

// pinned is the small adapter every Bins arm returns through: it applies the
// updater pin to the arm's binary list and propagates the fail-closed error,
// so no arm can forget the step and silently ship a stamp-versioned updater.
func pinned(bins []build.BinSpec, stamp, updaterVersion string) ([]build.BinSpec, error) {
	if err := applyUpdaterPin(bins, stamp, updaterVersion); err != nil {
		return nil, err
	}
	return bins, nil
}
