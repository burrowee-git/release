#!/usr/bin/env bash
# build.sh — cross-compile ONE Burrowee component for ONE target.
#
# Builds from the component's OWN source worktree, in MODULE mode: every build
# runs with GOWORK=off so the pinned go.mod versions resolve and a (gitignored)
# go.work in the worktree can never substitute local, unmerged module sources
# into a release binary. Each component emits one or more binaries; the
# binary→package map is fixed below. CGO is always off (pure-Go, portable).
#
# Env in (all required unless noted):
#   COMP          cli | gateway | edge | agent | relay | burrowee
#   SRC_DIR       the component's source worktree (cd target)
#   TARGETOS      GOOS  (darwin | linux)
#   TARGETARCH    GOARCH (arm64 | amd64)
#   STAMP           version string baked via -X main.version=…
#   OUT_DIR         output directory for the built binaries (created if absent)
#   CONSOLE_PUB_HEX edge + relay — baked via -X main.consolePubHexProd=… (console signing pubkey).
#                   Accepts the legacy BURROWEE_CLOUD_PUB / CLOUD_PUB_HEX names (env bridge).
#   CONSOLE_URL_PROD relay ONLY — console carrier URL baked via -X main.consoleURLProd=…
#                   (default wss://relay-api.burrowee.com; override via env).
#
# ldflags: always `-X main.version=$STAMP`. edge ALSO appends
#          `-X main.consolePubHexProd=$CONSOLE_PUB_HEX` to every edge binary.
#          relay bakes console identity (`-X main.consoleURLProd` +
#          `-X main.consolePubHexProd`) into burrowee-relay-cli + burrowee-relay-updater
#          ONLY — the serve binary (burrowee-relay) learns its console at bootstrap,
#          so it gets just `-X main.version`.
# darwin signing (only when TARGETOS=darwin AND the build host is darwin):
#   - default          → ad-hoc (`codesign --sign - --force`); macOS refuses to
#                        exec an unsigned native binary. For dev/CI/normal builds.
#   - APPLE_SIGN set    → real Developer ID signature via `modernech-sign sign`
#                        (hardened runtime + secure timestamp). RELEASE-only;
#                        release.sh sets it under its `--apple` flag. Notarization
#                        of the assembled zip happens in release.sh, not here.
# Cross-compiled (linux) outputs are left untouched.
#
# Optional env:
#   APPLE_SIGN     non-empty → Developer ID sign darwin outputs (release mode)
#   MODERNECH_SIGN path to the modernech-sign tool (default: PATH, then ~/bin)
set -euo pipefail

: "${COMP:?COMP is required (cli|gateway|edge|agent|relay|burrowee)}"
: "${SRC_DIR:?SRC_DIR is required (component source worktree)}"
: "${TARGETOS:?TARGETOS is required (darwin|linux)}"
: "${TARGETARCH:?TARGETARCH is required (arm64|amd64)}"
: "${STAMP:?STAMP is required}"
: "${OUT_DIR:?OUT_DIR is required}"

# env_or <new-var> <old-var> — echo $new if set, else $old (with a deprecation
# warning), else empty. Lets the new BURROWEE_CONSOLE_* names take effect while the
# legacy BURROWEE_CLOUD_* names keep working for one release (removed in N+1).
env_or() {
    eval "_nv=\${$1:-}"; eval "_ov=\${$2:-}"
    if [ -n "${_nv}" ]; then printf '%s' "${_nv}"; return; fi
    if [ -n "${_ov}" ]; then
        echo "⚠ deprecated env var ${2} — use ${1}" >&2
        printf '%s' "${_ov}"; return
    fi
}

GO_BIN="${GO_BIN:-go}"
command -v "${GO_BIN}" >/dev/null 2>&1 || GO_BIN=/opt/homebrew/bin/go
command -v "${GO_BIN}" >/dev/null 2>&1 || { echo "✗ go not found on PATH or /opt/homebrew/bin/go" >&2; exit 1; }

# shellcheck source=tools/updater_pin.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/updater_pin.sh"
# shellcheck source=tools/binmap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/binmap.sh"

# assert_workspace_off <build-dir> <gowork-value> — refuse to build unless the
# Go toolchain reports NO workspace in effect.
#
# Asked of `go env` instead of assumed. GOWORK="" is byte-identical in effect to
# GOWORK being unset: go walks up from <build-dir> and adopts any go.work it
# finds, silently replacing the pinned go.mod versions with whatever local
# worktrees that file points at. go.work is gitignored, so release.sh's
# source-cleanliness check cannot observe the substitution — and nothing else
# downstream can either. With bin_gowork hardcoded to "off" below, this
# assertion is a tautology TODAY; it is kept as a tripwire for the day someone
# reintroduces bin_gowork="" or a per-binary override, which is exactly the
# regression that would otherwise ship silently. `go env GOWORK` prints the
# adopted go.work path, or the literal "off"; only "off" may build a release.
assert_workspace_off() {
    local dir="$1" gowork="$2" seen
    seen="$( cd "${dir}" && GOWORK="${gowork}" "${GO_BIN}" env GOWORK )"
    [ "${seen}" = "off" ] || {
        echo "✗ ${COMP}: workspace mode is active for ${dir} — go env GOWORK = '${seen:-<unset>}', want 'off'." >&2
        echo "  A go.work here would build the release against LOCAL (possibly unmerged) module sources instead of the pinned go.mod versions, and go.work is gitignored so nothing downstream would notice. Refusing to build." >&2
        exit 1
    }
}

[ -d "${SRC_DIR}" ] || { echo "✗ SRC_DIR '${SRC_DIR}' is not a directory" >&2; exit 1; }

# Resolve the shared Modernech signer once, only when release-mode Apple signing
# is requested (keeps normal/dev builds free of any dependency on it).
if [ -n "${APPLE_SIGN:-}" ]; then
    SIGN_BIN="${MODERNECH_SIGN:-modernech-sign}"
    command -v "${SIGN_BIN}" >/dev/null 2>&1 || SIGN_BIN="${HOME}/bin/modernech-sign"
    command -v "${SIGN_BIN}" >/dev/null 2>&1 \
        || { echo "✗ APPLE_SIGN set but modernech-sign not found on PATH or ~/bin" >&2; exit 1; }
fi

# binary -> package map (space-separated "bin:pkg" pairs per component).
#
# The list itself lives in tools/binmap.sh — the ONE shell copy, shared with
# tools/release.sh's bins_for (which selects, by name, what the zip carries out
# of what this script builds) and cross-checked against internal/relconfig.Bins
# by internal/relconfig/binmap_cross_check_test.go. This used to be an
# independent `case` here: a binary added to it and not to bins_for was built,
# signed, notarized and then silently left out of the payload.
#
# bin_map names the components it knows and exits 2 on any other, which is the
# validation the old `*)` arm did.
MAP="$(bin_map "${COMP}")" || exit 2

# ldflags
LDFLAGS="-X main.version=${STAMP}"
if [ "${COMP}" = "agent" ]; then
    # agent keeps its version var in internal/agent/command (the dispatch table
    # prints it), not package main — stamp that symbol; the main.version -X is a
    # silent no-op there.
    LDFLAGS="${LDFLAGS} -X github.com/burrowee-git/agent/internal/agent/command.version=${STAMP}"
fi
if [ "${COMP}" = "edge" ]; then
    # Resolve the console signing pubkey: prefer CONSOLE_PUB_HEX (passed by
    # release.sh from config/console-pub.hex), then the legacy CLOUD_PUB_HEX, then
    # the operator's BURROWEE_CONSOLE_PUB / BURROWEE_CLOUD_PUB exports.
    CONSOLE_PUB_HEX="$(env_or CONSOLE_PUB_HEX CLOUD_PUB_HEX)"
    [ -n "${CONSOLE_PUB_HEX}" ] || CONSOLE_PUB_HEX="$(env_or BURROWEE_CONSOLE_PUB BURROWEE_CLOUD_PUB)"
    : "${CONSOLE_PUB_HEX:?CONSOLE_PUB_HEX is required for edge builds (console signing pubkey hex)}"
    # The 64-zero placeholder is valid hex of valid length, so edge's runtime check
    # cannot catch it — it would silently pin a dead key. Reject it at build time.
    [ "${CONSOLE_PUB_HEX}" != "0000000000000000000000000000000000000000000000000000000000000000" ] || {
        echo "✗ CONSOLE_PUB_HEX is the placeholder — set config/console-pub.hex to the real console signing key before an edge release" >&2
        exit 1
    }
    LDFLAGS="${LDFLAGS} -X main.consolePubHexProd=${CONSOLE_PUB_HEX}"
fi

# relay: the cli + updater bake console identity (carrier URL + signing pubkey); the
# serve binary (burrowee-relay) does NOT — it learns its console at bootstrap. So
# relay applies these flags PER-BINARY in the build loop, never via the global
# LDFLAGS (which would wrongly bake the key into the serve binary too).
RELAY_CONSOLE_LDFLAGS=""
if [ "${COMP}" = "relay" ]; then
    CONSOLE_PUB_HEX="$(env_or CONSOLE_PUB_HEX CLOUD_PUB_HEX)"
    [ -n "${CONSOLE_PUB_HEX}" ] || CONSOLE_PUB_HEX="$(env_or BURROWEE_CONSOLE_PUB BURROWEE_CLOUD_PUB)"
    : "${CONSOLE_PUB_HEX:?CONSOLE_PUB_HEX is required for relay builds (console signing pubkey hex)}"
    # The 64-zero placeholder is valid hex of valid length, so the runtime check
    # cannot catch it — it would silently pin a dead key. Reject it (mirrors edge).
    [ "${CONSOLE_PUB_HEX}" != "0000000000000000000000000000000000000000000000000000000000000000" ] || {
        echo "✗ CONSOLE_PUB_HEX is the placeholder — set config/console-pub.hex to the real console signing key before a relay release" >&2
        exit 1
    }
    CONSOLE_URL_PROD="${CONSOLE_URL_PROD:-wss://relay-api.burrowee.com}"
    RELAY_CONSOLE_LDFLAGS="-X main.consoleURLProd=${CONSOLE_URL_PROD} -X main.consolePubHexProd=${CONSOLE_PUB_HEX}"
fi

mkdir -p "${OUT_DIR}"
HOST_OS="$(uname -s)"

# VARIANT ("" | legacy) — darwin-amd64-legacy applies the crypto/x509 overlay
# (spec §4.2) so the resulting binary avoids the macOS-12-only SecTrust API.
# Scoped to darwin/amd64 only; every other target keeps building unmodified.
VARIANT="${VARIANT:-}"
OVERLAY_FLAG=()
case "${VARIANT}" in
    "") ;;
    legacy)
        [ "${TARGETOS}" = darwin ] && [ "${TARGETARCH}" = amd64 ] \
            || { echo "✗ legacy variant is darwin/amd64 only (got ${TARGETOS}/${TARGETARCH})" >&2; exit 2; }
        LEGACY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/legacy/darwin" && pwd)"
        bash "${LEGACY_DIR}/overlay.test.sh" >/dev/null \
            || { echo "✗ legacy overlay drift guard failed — see: bash ${LEGACY_DIR}/overlay.test.sh" >&2; exit 1; }
        bash "${LEGACY_DIR}/overlay-json.sh" "${OUT_DIR}/.overlay.json"
        OVERLAY_FLAG=(-overlay "${OUT_DIR}/.overlay.json")
        # shellcheck source=tools/legacy/darwin/symbols.sh
        source "${LEGACY_DIR}/symbols.sh"
        ;;
    *) echo "✗ unknown VARIANT '${VARIANT}' (use '' or legacy)" >&2; exit 2 ;;
esac

# shellcheck disable=SC2086  # ${MAP} is an intentional space-list of "bin:pkg" pairs; word-splitting into pairs is the point.
for pair in ${MAP}; do
    bin="${pair%%:*}"
    pkg="${pair#*:}"
    out="${OUT_DIR}/${bin}"
    # Per-binary ldflags: relay bakes console identity into the cli + updater only.
    bin_ldflags="${LDFLAGS}"
    build_dir="${SRC_DIR}"
    # GOWORK is "off" for EVERY release build — never "".
    #
    # GOWORK="" is indistinguishable from GOWORK being unset: go still walks up
    # from the build dir and adopts any go.work it finds. Component worktrees
    # carry a per-worktree go.work (the concurrency mechanism) that `use`s LOCAL
    # core/console checkouts, and it is gitignored — so release.sh's
    # source-cleanliness check structurally cannot see it, and a cut would
    # silently ship unmerged core against a pinned-tag go.mod. release-kit's
    # build/build.go defaults this to "off" for exactly this reason; this script
    # has to match. Verified below (assert_workspace_off) rather than assumed.
    bin_gowork="off"
    if [ "${COMP}" = "relay" ]; then
        case "${bin}" in
            burrowee-relay-cli|burrowee-relay-updater)
                bin_ldflags="${LDFLAGS} ${RELAY_CONSOLE_LDFLAGS}"
                # The relay cli tree is a NESTED Go module (cli/go.mod pinning
                # core by tag), so it must be built from INSIDE that module for
                # the pinned tags to resolve — from SRC_DIR the package only
                # resolves in workspace mode. (GOWORK=off is the default for
                # every binary; see bin_gowork above.)
                build_dir="${SRC_DIR}/cli"
                pkg=".${pkg#./cli}"   # ./cli → . ; ./cli/cmd/x → ./cmd/x
                ;;
        esac
    fi
    # The updater binary's version is the core/updater module pin, not the
    # component STAMP — so it stays stable across cuts that don't repin
    # core/updater. Substitute ONLY the "-X main.version=${STAMP}" term inside
    # the already-computed bin_ldflags — do NOT rebuild bin_ldflags wholesale,
    # or component-specific flags baked into the global LDFLAGS (e.g. edge's
    # consolePubHexProd) get silently dropped from the updater binary. Relay's
    # console-identity flags (already appended into bin_ldflags above, for
    # burrowee-relay-updater) survive the same way.
    bin_version="${STAMP}"
    case "${bin}" in
        *-updater)
            bin_version="$(updater_pin "${build_dir}")"
            bin_ldflags="${bin_ldflags/-X main.version=${STAMP}/-X main.version=${bin_version}}"
            # FAIL CLOSED. The line above is a bash pattern substitution: when the
            # pattern does not match it substitutes NOTHING and says NOTHING, so
            # the updater silently ships carrying the component STAMP instead of
            # the core/updater pin. That shipped in edge v0.1.99 and relay
            # v0.1.36 — both nodes reported their component version as their
            # updater version, which permanently mismatches the catalog's
            # updater_version and makes the console offer an update that can
            # never converge. The echo below prints bin_version either way, so
            # the build log looked correct while the binary was wrong; assert on
            # the LDFLAGS, never on the intended value.
            case "${bin_ldflags}" in
                *"-X main.version=${bin_version}"*) ;;
                *) echo "✗ ${bin}: updater pin substitution did not apply — ldflags still '${bin_ldflags}' (wanted -X main.version=${bin_version}). Refusing to ship an updater stamped with the component version." >&2; exit 1 ;;
            esac
            ;;
    esac
    echo "→ ${COMP}: ${bin}  (GOOS=${TARGETOS} GOARCH=${TARGETARCH}, version=${bin_version}${VARIANT:+ variant=${VARIANT}})"
    assert_workspace_off "${build_dir}" "${bin_gowork}"
    ( cd "${build_dir}" && CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" GOWORK="${bin_gowork}" \
        "${GO_BIN}" build -trimpath ${OVERLAY_FLAG[@]+"${OVERLAY_FLAG[@]}"} -ldflags "${bin_ldflags}" -o "${out}" "${pkg}" )
    if [ "${VARIANT}" = legacy ]; then
        assert_legacy_symbols "${out}" || exit 1
    fi
    if [ "${TARGETOS}" = "darwin" ] && [ "${HOST_OS}" = "Darwin" ]; then
        if [ -n "${APPLE_SIGN:-}" ]; then
            # release mode: real Developer ID signature (hardened runtime + timestamp)
            "${SIGN_BIN}" sign "${out}" >&2
        else
            # default: ad-hoc — macOS only needs *a* signature to exec the binary
            codesign --sign - --force "${out}" >/dev/null 2>&1 || true
        fi
    fi
    echo "✓ ${out}"
done
