#!/usr/bin/env bash
# build.sh — cross-compile ONE Burrowee component for ONE target.
#
# Builds from the component's OWN source worktree (so its local go.mod /
# go.work resolves `core`). Each component emits one or more binaries; the
# binary→package map is fixed below. CGO is always off (pure-Go, portable).
#
# Env in (all required unless noted):
#   COMP          cli | gateway | edge | burrowee
#   SRC_DIR       the component's source worktree (cd target)
#   TARGETOS      GOOS  (darwin | linux)
#   TARGETARCH    GOARCH (arm64 | amd64)
#   STAMP           version string baked via -X main.version=…
#   OUT_DIR         output directory for the built binaries (created if absent)
#   CONSOLE_PUB_HEX edge ONLY — baked via -X main.consolePubHexProd=… (console signing pubkey).
#                   Accepts the legacy BURROWEE_CLOUD_PUB / CLOUD_PUB_HEX names (env bridge).
#
# ldflags: always `-X main.version=$STAMP`; edge ALSO appends
#          `-X main.consolePubHexProd=$CONSOLE_PUB_HEX`.
# If TARGETOS=darwin and the build host is darwin, each output is ad-hoc
# codesigned (`codesign --sign - --force`) — macOS refuses to exec unsigned
# native binaries. Cross-compiled (linux) outputs are left untouched.
set -euo pipefail

: "${COMP:?COMP is required (cli|gateway|edge|burrowee)}"
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

[ -d "${SRC_DIR}" ] || { echo "✗ SRC_DIR '${SRC_DIR}' is not a directory" >&2; exit 1; }

# binary -> package map (space-separated "bin:pkg" pairs per component)
case "${COMP}" in
    cli)      MAP="burrowee-cli:./cmd/burrowee-cli" ;;
    gateway)  MAP="burrowee-gateway:./cmd/burrowee-gateway burrowee-register:./cmd/burrowee-register" ;;
    edge)     MAP="burrowee-edge:./cmd/burrowee-edge" ;;
    burrowee) MAP="burrowee:." ;;   # dispatcher main package is the repo root
    *)        echo "✗ unknown COMP: ${COMP}" >&2; exit 2 ;;
esac

# ldflags
LDFLAGS="-X main.version=${STAMP}"
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

mkdir -p "${OUT_DIR}"
HOST_OS="$(uname -s)"

cd "${SRC_DIR}"
# shellcheck disable=SC2086  # ${MAP} is an intentional space-list of "bin:pkg" pairs; word-splitting into pairs is the point.
for pair in ${MAP}; do
    bin="${pair%%:*}"
    pkg="${pair#*:}"
    out="${OUT_DIR}/${bin}"
    echo "→ ${COMP}: ${bin}  (GOOS=${TARGETOS} GOARCH=${TARGETARCH}, version=${STAMP})"
    CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" \
        "${GO_BIN}" build -trimpath -ldflags "${LDFLAGS}" -o "${out}" "${pkg}"
    if [ "${TARGETOS}" = "darwin" ] && [ "${HOST_OS}" = "Darwin" ]; then
        codesign --sign - --force "${out}" >/dev/null 2>&1 || true
    fi
    echo "✓ ${out}"
done
