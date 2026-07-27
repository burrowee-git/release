#!/usr/bin/env bash
# test-build-updater-stamp.sh — prove burrowee-edge-updater is stamped from the
# pinned github.com/burrowee-git/core/updater module version, NOT the component
# STAMP that every other binary in the build map gets.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; repo="$(cd "$here/.." && pwd)"

src="${EDGE_SRC:?set EDGE_SRC to the edge worktree}"
GO_BIN="${GO_BIN:-go}"
command -v "${GO_BIN}" >/dev/null 2>&1 || GO_BIN=/opt/homebrew/bin/go

pin="$(cd "$src" && "${GO_BIN}" list -m -f '{{.Version}}' github.com/burrowee-git/core/updater)"

stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT

COMP=edge SRC_DIR="$src" TARGETOS="$(go env GOOS)" TARGETARCH="$(go env GOARCH)" \
  STAMP="v9.9.9.2026.01.01.deadbeef" OUT_DIR="$stage" GO_BIN="${GO_BIN}" \
  CONSOLE_PUB_HEX="6b63fcb13ec04e1fe37bfc6fe9b286378943363a04e18dfc02306d1fa47cba3d" \
  bash "${repo}/tools/build.sh"

# `version` prints a multi-line installed-vs-running report (runtime_version.Report);
# the installed binary's stamp is field 2 of line 1: "burrowee-edge-updater <version>  (installed binary)".
got="$("$stage/burrowee-edge-updater" version | head -n1 | awk '{print $2}')"
[ "$got" = "$pin" ] || { echo "FAIL updater stamp: got '$got' want pin '$pin'"; exit 1; }
[ "$got" != "v9.9.9.2026.01.01.deadbeef" ] || { echo "FAIL updater got component STAMP"; exit 1; }

echo "PASS updater stamped from pin ($pin)"
