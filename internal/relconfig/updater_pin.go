package relconfig

// updater_pin.go — the updater binary's version is the core/updater MODULE PIN,
// not the component stamp, carrying the pin's OWN date + changeset fp:
// <semver>.<YYYY.MM.DD>.<sha8>. Mirrors tools/build.sh's updater_pin() (extracted
// to tools/updater_pin.sh) contract so the two produce paths (release.sh→build.sh
// and rkit) emit the IDENTICAL stamp for the same pin — see
// TestUpdaterPinMatchesBashHelper, which pins the mirror itself.
//
// WHY THIS EXISTS AT ALL: rkit had no updater stamping, so every rkit cut baked
// the component stamp into `burrowee-<comp>-updater`. A node then reports its
// component version as its updater version, which can never equal the catalog's
// updater_version (the pin) — so the console offers an updater update forever
// and the two-phase push runs a phase that cannot converge. Shipped that way in
// edge v0.1.99.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/burrowee-git/release-kit/build"
)

// cleanTag matches a release tag and nothing else: no pseudo-versions, no
// pre-release or build suffixes. A pin that is not a clean tag means someone is
// building against a branch or a replace, which must never reach a cut.
var cleanTag = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)

// hexHash matches a leading run of lowercase-hex digits, at least 8 of them —
// mirroring tools/updater_pin.sh's `[0-9a-f]*` sed extraction so both sides
// reject the same malformed Origin.Hash values identically.
var hexHash = regexp.MustCompile(`^[0-9a-f]{8,}`)

// updaterModDownload is the subset of `go mod download -json`'s output this
// package needs: the absolute path to the module's cached .info file. Reading
// the path go itself reports avoids hand-constructing
// $GOMODCACHE/cache/download/... paths.
type updaterModDownload struct {
	Info string
}

// updaterModMeta is the subset of a module .info file this package needs: the
// commit time and the origin changeset hash. `go list -m` does NOT surface
// Origin, which is why the .info file is read instead of queried.
type updaterModMeta struct {
	Time   time.Time
	Origin struct {
		Hash string
	}
}

// UpdaterPin resolves the github.com/burrowee-git/core/updater version pinned by
// the module in modDir, rejecting anything but a clean tag, and returns the
// updater's full stamp: <semver>.<YYYY.MM.DD>.<sha8>. For relay the caller
// passes the NESTED cli module dir, which is where its updater lives.
//
// All three parts come from the PIN's own module metadata, never from this
// build, so the stamp is FROZEN while the pin is unchanged — the property this
// function has always existed to protect (the updater must not be re-versioned
// by a cut that did not repin core/updater) now extended to the date and
// fingerprint. Same freeze semantics as tools/updater_pin.sh and
// versions/burrowee.stamp for the dispatcher.
//
// Returns ("", nil) when the module has no core/updater dependency at all — the
// agent's case. Callers keep the component stamp for those binaries, matching
// build.sh, which excludes agent from pin resolution for the same reason. This
// is the ONE case that is not an error: once the module IS a dependency and IS
// pinned to a clean tag, every further failure below is returned, never
// swallowed — a missing Time or Origin.Hash would otherwise yield "v0.1.12.."
// or "v0.1.12.2026.07.26." — a malformed stamp reaching the console catalog and
// the fleet.
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

	// From here the module IS a dependency, pinned to a clean tag — every
	// further failure is a real error. FAIL CLOSED: an empty result aborts the
	// build instead of shipping a wrong or malformed version.
	dlCmd := exec.CommandContext(ctx, goBin, "mod", "download", "-json", "github.com/burrowee-git/core/updater")
	dlCmd.Dir = modDir
	dlOut, err := dlCmd.Output()
	if err != nil {
		return "", fmt.Errorf("relconfig: core/updater %s: go mod download -json in %s: %w", v, modDir, err)
	}
	var dl updaterModDownload
	if err := json.Unmarshal(dlOut, &dl); err != nil || dl.Info == "" {
		return "", fmt.Errorf("relconfig: core/updater %s: could not resolve module .info path via 'go mod download -json' in %s", v, modDir)
	}
	raw, err := os.ReadFile(dl.Info)
	if err != nil {
		return "", fmt.Errorf("relconfig: core/updater %s: could not read module info %s: %w", v, dl.Info, err)
	}
	var meta updaterModMeta
	if err := json.Unmarshal(raw, &meta); err != nil {
		return "", fmt.Errorf("relconfig: core/updater %s: could not parse module info %s: %w", v, dl.Info, err)
	}
	if meta.Time.IsZero() {
		return "", fmt.Errorf("relconfig: core/updater %s: no usable Time in %s — refusing to ship a malformed updater stamp", v, dl.Info)
	}
	if !hexHash.MatchString(meta.Origin.Hash) {
		return "", fmt.Errorf("relconfig: core/updater %s: no usable Origin.Hash in %s (got %q) — refusing to ship a malformed updater stamp", v, dl.Info, meta.Origin.Hash)
	}
	date := meta.Time.UTC().Format("2006.01.02")
	fp := meta.Origin.Hash[:8]
	return fmt.Sprintf("%s.%s.%s", v, date, fp), nil
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

// UpdaterModuleDir returns the module dir whose go.mod pins core/updater for
// comp's updater binary. Relay's updater is built from the NESTED `cli` module,
// not the repo root — build.sh has the same special case ("relay's updater
// build_dir is the nested `cli` module"). Missing it here meant relay's pin
// resolved against a module with no core/updater dependency, UpdaterPin returned
// the no-dependency empty string, and the updater silently kept the component
// stamp: relay v0.1.37 built with burrowee-relay-updater reporting v0.1.37.
func UpdaterModuleDir(comp, srcDir string) string {
	if comp == "relay" {
		return filepath.Join(srcDir, "cli")
	}
	return srcDir
}

// RequiresUpdaterPin reports whether comp MUST resolve a core/updater pin.
//
// NOT YET ENFORCED at the rkit call site: rkit's build tests use minimal scratch
// modules with no core/updater dependency, so asserting there fails them. Wiring
// this in needs those fixtures to declare the dependency — tracked as follow-up.
// UpdaterModuleDir fixes the bug that motivated it; this closes the remaining
// ambiguity between "no dependency" and "wrong directory".
// Only agent legitimately has none (no core/updater dependency at all), which
// is exactly how release.sh phrases it — it skips agent at the caller.
//
// This exists because UpdaterPin's "no dependency → empty string" answer is
// indistinguishable from "I looked in the wrong directory". That ambiguity is
// what let the relay bug through: the pin came back empty, the stamp stood, and
// nothing complained. Callers assert on this so a wrong module dir fails the
// cut instead of shipping a mis-stamped binary.
func RequiresUpdaterPin(comp string) bool { return comp != "agent" && comp != "burrowee" }
