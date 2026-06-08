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
#   STAMP         version string baked via -X main.version=…
#   OUT_DIR       output directory for the built binaries (created if absent)
#   CLOUD_PUB_HEX edge ONLY — baked via -X main.cloudPubHexProd=… (cloud signing pubkey)
#
# ldflags: always `-X main.version=$STAMP`; edge ALSO appends
#          `-X main.cloudPubHexProd=$CLOUD_PUB_HEX`.
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
    : "${CLOUD_PUB_HEX:?CLOUD_PUB_HEX is required for edge builds (cloud signing pubkey hex)}"
    # The 64-zero placeholder is valid hex of valid length, so edge's runtime check
    # cannot catch it — it would silently pin a dead key. Reject it at build time.
    [ "${CLOUD_PUB_HEX}" != "0000000000000000000000000000000000000000000000000000000000000000" ] || {
        echo "✗ CLOUD_PUB_HEX is the placeholder — set config/cloud-pub.hex to the real console signing key before an edge release" >&2
        exit 1
    }
    LDFLAGS="${LDFLAGS} -X main.cloudPubHexProd=${CLOUD_PUB_HEX}"
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
