#!/usr/bin/env bash
# test-build-updater-stamp.sh — prove burrowee-edge-updater is stamped from the
# pinned github.com/burrowee-git/core/updater module's own full stamp (semver +
# date + changeset fp), NOT the component STAMP that every other binary in the
# build map gets.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; repo="$(cd "$here/.." && pwd)"

# ── the pin's own contract, hermetically ─────────────────────────────────────
# updater_pin's classification and rendering, driven through its GO_BIN seam
# against a fake `go` answering from two env-fed values — no build, no module
# cache, no worktree. The build half below proves the stamp reaches the
# binary; this half proves what the stamp IS, both ways:
#
#   * a clean tag renders <tag>.<date>.<sha8>;
#   * a semver PRE-RELEASE tag (core/updater is pinned at core/vX.Y.0-beta.N
#     for the whole of a beta cycle — the Burrowee manual's own rule for a
#     surface-changing core tag) is ACCEPTED, and renders with the dotted
#     infix every shipped stamp uses (v0.3.0.beta.1.<date>.<sha8>, matching
#     versions/*.beta.stamp's v0.2.17.beta.… shape) — a hyphen in the stamp
#     would be a shape nothing downstream has ever parsed;
#   * a true PSEUDO-VERSION (…-0.yyyymmddhhmmss-<12 hex>, tagless or based on
#     either kind of tag) is still REFUSED: it means the pin is not a tag at
#     all, and a cut must not freeze the updater to an untagged commit.
fakego="$(mktemp -d)"
cat > "${fakego}/go" <<'FAKEGO'
#!/bin/sh
case "$1 $2" in
"list -m") printf '%s
' "${FAKE_PIN_VERSION}" ;;
"mod download") printf '{"Info": "%s"}
' "${FAKE_PIN_INFO}" ;;
*) echo "fake go: unexpected argv: $*" >&2; exit 1 ;;
esac
FAKEGO
chmod 0755 "${fakego}/go"
info="${fakego}/pin.info"
printf '{"Version":"x","Time":"2026-08-30T12:34:56Z","Origin":{"VCS":"git","Hash":"0123456789abcdef01234567"}}
' > "${info}"

# pin_case <version> <want-stamp|REFUSE> <label> — updater_pin in a subshell
# (it exits the shell on refusal), against the fake go.
pin_case() {
    local v="$1" want="$2" label="$3" got rc
    set +e
    got="$(FAKE_PIN_VERSION="${v}" FAKE_PIN_INFO="${info}" GO_BIN="${fakego}/go" updater_pin "${fakego}" 2>&1)"
    rc=$?
    set -e
    if [ "${want}" = REFUSE ]; then
        [ "${rc}" -ne 0 ] || { echo "FAIL ${label}: '${v}' was accepted with stamp '${got}', want a refusal"; exit 1; }
        case "${got}" in *"pseudo-version"*|*"non-tag"*) : ;; *) echo "FAIL ${label}: the refusal does not say why: ${got}"; exit 1 ;; esac
    else
        [ "${rc}" -eq 0 ] || { echo "FAIL ${label}: '${v}' was refused: ${got}"; exit 1; }
        [ "${got}" = "${want}" ] || { echo "FAIL ${label}: got '${got}' want '${want}'"; exit 1; }
    fi
    echo "PASS ${label}"
}

# shellcheck source=tools/updater_pin.sh
source "$(cd "$(dirname "$0")" && pwd)/updater_pin.sh"
pin_case v0.1.12 "v0.1.12.2026.08.30.01234567" "clean tag renders <tag>.<date>.<sha8>"
pin_case v0.3.0-beta.1 "v0.3.0.beta.1.2026.08.30.01234567" "a pre-release tag is accepted and rendered with the dotted infix"
pin_case v0.3.1-0.20260830120000-0123456789ab REFUSE "a tagless pseudo-version is refused"
pin_case v0.3.0-beta.1.0.20260830120000-0123456789ab REFUSE "a pseudo-version based on a pre-release tag is refused"
pin_case v0.3.0-20260830120000-0123456789ab REFUSE "a pseudo-version missing the .0. rung is still not a tag"
rm -rf "${fakego}"

# ── the build half: the stamp reaches the binary ─────────────────────────────
src="${EDGE_SRC:?set EDGE_SRC to the edge worktree}"
GO_BIN="${GO_BIN:-go}"
command -v "${GO_BIN}" >/dev/null 2>&1 || GO_BIN=/opt/homebrew/bin/go

# shellcheck source=tools/updater_pin.sh
source "${repo}/tools/updater_pin.sh"
pin="$(cd "$src" && updater_pin .)"

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
