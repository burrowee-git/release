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

# A sentinel (not the real console pubkey, not the all-zero placeholder build.sh
# rejects) — proves the *-updater override only swaps the version term, and
# does not drop the other -X flags baked into the global LDFLAGS (regression:
# a wholesale bin_ldflags rebuild silently dropped consolePubHexProd from
# burrowee-edge-updater, which then log.Fatals pre-bootstrap at runtime).
sentinel_pub_hex="deadbeefsentine1deadbeefsentine1deadbeefsentine1deadbeefsentine1"

COMP=edge SRC_DIR="$src" TARGETOS="$(go env GOOS)" TARGETARCH="$(go env GOARCH)" \
  STAMP="v9.9.9.2026.01.01.deadbeef" OUT_DIR="$stage" GO_BIN="${GO_BIN}" \
  CONSOLE_PUB_HEX="${sentinel_pub_hex}" \
  bash "${repo}/tools/build.sh"

# `version` prints a multi-line installed-vs-running report (runtime_version.Report);
# the installed binary's stamp is field 2 of line 1: "burrowee-edge-updater <version>  (installed binary)".
got="$("$stage/burrowee-edge-updater" version | head -n1 | awk '{print $2}')"
[ "$got" = "$pin" ] || { echo "FAIL updater stamp: got '$got' want pin '$pin'"; exit 1; }
[ "$got" != "v9.9.9.2026.01.01.deadbeef" ] || { echo "FAIL updater got component STAMP"; exit 1; }

# Capture strings' output into a variable before grepping it — piping straight
# into `grep -q` under `pipefail` is flaky: grep can exit as soon as it finds a
# match, SIGPIPE-ing `strings` while it's still writing, which under pipefail
# fails the whole pipeline (exit 141) even though the match was found.
bin_strings="$(strings "$stage/burrowee-edge-updater")"
grep -q "${sentinel_pub_hex}" <<<"${bin_strings}" \
  || { echo "FAIL updater dropped consolePubHexProd (sentinel '${sentinel_pub_hex}' not found in binary)"; exit 1; }

echo "PASS updater stamped from pin ($pin) and kept consolePubHexProd"
