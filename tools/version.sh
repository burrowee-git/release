#!/usr/bin/env bash
# version.sh — per-component version + deploy stamp for the Burrowee release repo.
#
# Each component (cli|gateway|edge|agent|relay|burrowee) has its own one-line
# MAJOR.MINOR.PATCH file under versions/<comp> — the single source of
# truth for that component's semver segment. This composes the full
# stamp used in ldflags, git tags, and marker commits:
#
#   v<X.Y.Z>.<YYYY>.<MM>.<DD>.<sha8>
#
# where <sha8> = the HEAD short hash of the COMPONENT SOURCE worktree
# (pass its path via SRC_DIR), and the date is today (UTC).
#
# A second channel, beta, tracks its own semver in versions/<comp>.beta —
# that file's PRESENCE is the open-beta-cycle flag — and its stamp carries
# an extra .beta. segment between the semver and the date:
#
#   v<X.Y.Z>.beta.<YYYY>.<MM>.<DD>.<sha8>
#
# so a whole-string `sort -V` still orders by semver first, and one anchored
# regex tells the two channels apart.
#
# Usage:
#   tools/version.sh <comp> [--channel stable|beta] --semver       # just X.Y.Z
#   tools/version.sh <comp> [--channel stable|beta] --stamp        # full stamp (needs SRC_DIR)
#   tools/version.sh <comp> [--channel stable|beta] --bump-patch   # X.Y.(Z+1)  + git add versions/<comp>[.beta]
#   tools/version.sh <comp> [--channel stable|beta] --bump-minor   # X.(Y+1).0  + git add versions/<comp>[.beta] (gated)
#   tools/version.sh <comp> [--channel stable|beta] --bump-major   # (X+1).0.0  + git add versions/<comp>[.beta] (gated)
#   tools/version.sh <comp> --channel beta --assert-beta-above-stable
#                                           # refuses (exit 1) unless versions/<comp>.beta > versions/<comp>
#
# --channel defaults to stable. Minor/major prompt unless
# BURROWEE_RELEASE_YES=1 (or non-TTY → refuse).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

COMP="${1:-}"
case "${COMP}" in
    cli|gateway|edge|agent|relay|burrowee) ;;
    "")  echo "✗ usage: version.sh <cli|gateway|edge|agent|relay|burrowee> <action>" >&2; exit 2 ;;
    *)   echo "✗ unknown component: ${COMP}" >&2; exit 2 ;;
esac

CHANNEL=stable
if [ "${2:-}" = "--channel" ]; then
    CHANNEL="${3:-}"; shift 2
    case "${CHANNEL}" in
        stable|beta) ;;
        *) echo "✗ --channel must be stable or beta (got '${CHANNEL}')" >&2; exit 2 ;;
    esac
fi

VERSION_FILE="${REPO_ROOT}/versions/${COMP}"
[ "${CHANNEL}" = beta ] && VERSION_FILE="${REPO_ROOT}/versions/${COMP}.beta"
VERSION_REL="${VERSION_FILE#"${REPO_ROOT}"/}"
[ -f "${VERSION_FILE}" ] || {
    if [ "${CHANNEL}" = beta ]; then
        echo "✗ ${VERSION_REL} not found at ${VERSION_FILE} — open a beta cycle: create it with the next minor (stable+1), patch 0" >&2
    else
        echo "✗ ${VERSION_REL} not found at ${VERSION_FILE}" >&2
    fi
    exit 1
}

read_semver() {
    local raw; raw="$(tr -d '\r\n[:space:]' < "${VERSION_FILE}")"
    [[ "${raw}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ ${VERSION_REL} '${raw}' not MAJOR.MINOR.PATCH" >&2; exit 1; }
    printf '%s' "${raw}"
}
# Side-effect: stages versions/<comp>[.beta] so the caller (release.sh) can commit/revert it as one unit.
write_semver() { printf '%s\n' "$1" > "${VERSION_FILE}"; ( cd "${REPO_ROOT}" && git add "${VERSION_REL}" ); }

src_sha() {
    [ -n "${SRC_DIR:-}" ] || { echo "✗ --stamp needs SRC_DIR (the component source worktree)" >&2; exit 2; }
    [ -d "${SRC_DIR}" ]   || { echo "✗ SRC_DIR '${SRC_DIR}' not a directory" >&2; exit 1; }
    git -C "${SRC_DIR}" rev-parse --short=8 HEAD 2>/dev/null \
        || { echo "✗ SRC_DIR '${SRC_DIR}' is not a git worktree" >&2; exit 1; }
}
today_utc() { date -u +%Y.%m.%d; }
stamp() {
    if [ "${CHANNEL}" = beta ]; then
        printf 'v%s.beta.%s.%s' "$1" "$(today_utc)" "$2"
    else
        printf 'v%s.%s.%s' "$1" "$(today_utc)" "$2"
    fi
}

bump() {
    local kind="$1" cur major minor patch new
    cur="$(read_semver)"; IFS='.' read -r major minor patch <<<"${cur}"
    case "${kind}" in
        patch) new="${major}.${minor}.$((patch+1))" ;;
        minor) new="${major}.$((minor+1)).0" ;;
        major) new="$((major+1)).0.0" ;;
        *) echo "✗ unknown bump kind: ${kind}" >&2; exit 1 ;;
    esac
    if [ "${kind}" != "patch" ] && [ "${BURROWEE_RELEASE_YES:-0}" != "1" ]; then
        [ -t 0 ] || { echo "✗ ${kind} bump ${cur}→${new} needs a TTY or BURROWEE_RELEASE_YES=1" >&2; exit 1; }
        printf '%s %s bump %s → %s. Continue? [y/N] ' "${COMP}" "${kind}" "${cur}" "${new}" >&2
        local r; read -r r; case "${r}" in y|Y|yes|YES) ;; *) echo "✗ aborted" >&2; exit 1 ;; esac
    fi
    write_semver "${new}"; printf '%s\n' "${new}"
}

case "${2:-}" in
    --semver)      read_semver; printf '\n' ;;
    --stamp)       _sv="$(read_semver)"; _sha="$(src_sha)"; stamp "${_sv}" "${_sha}"; printf '\n' ;;
    --bump-patch)  bump patch ;;
    --bump-minor)  bump minor ;;
    --bump-major)  bump major ;;
    --assert-beta-above-stable)
        [ "${CHANNEL}" = beta ] || { echo "✗ --assert-beta-above-stable needs --channel beta" >&2; exit 2; }
        STABLE_FILE="${REPO_ROOT}/versions/${COMP}"
        [ -f "${STABLE_FILE}" ] || { echo "✗ versions/${COMP} not found at ${STABLE_FILE}" >&2; exit 1; }
        _b="$(read_semver)"
        _s="$(tr -d '\r\n[:space:]' < "${STABLE_FILE}")"
        if [ "$(printf '%s\n%s\n' "${_s}" "${_b}" | sort -V | tail -n1)" != "${_b}" ] || [ "${_s}" = "${_b}" ]; then
            echo "✗ versions/${COMP}.beta (${_b}) must sort above versions/${COMP} (${_s}) — a beta must read newer than every stable so a beta node's \`version\` output and the follow-on stable cut both land right; fix with: tools/version.sh ${COMP} --channel beta --bump-minor (or --bump-patch)" >&2
            exit 1
        fi ;;
    -h|--help)     sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//' ;;
    "")            echo "✗ usage: version.sh ${COMP} <--semver|--stamp|--bump-patch|--bump-minor|--bump-major|--assert-beta-above-stable>" >&2; exit 2 ;;
    *)             echo "✗ unknown action: ${2}" >&2; exit 2 ;;
esac
