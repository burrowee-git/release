#!/usr/bin/env bash
# cut-status.sh — which cut components have landed work that is NOT released.
#
# A component's stamp (versions/<comp>.stamp) ends in the source sha8 the last
# cut was built from. Compare that to the component's current origin/main and
# you get, per component, whether anything has landed since it shipped.
#
# WHY THIS EXISTS: cutting one component at a time drifts the fleet — a fix
# merges, attention moves on, and the release that would have carried it never
# happens. Nothing in the repo showed that; you had to remember. This makes
# "cut everything updated since its last cut" checkable instead of remembered.
#
# The component SET is derived from versions/ (what release.sh actually bumps),
# so a component added there shows up here with no edit. The component→source
# mapping mirrors release.sh's src_for() and honours the same BURROWEE_SRC_*
# overrides.
#
# Usage: bash tools/cut-status.sh [--no-fetch] [--quiet]
#   --no-fetch  skip `git fetch` and compare against local origin/main refs
#   --quiet     print only stale components, one per line (for scripting)
#
# Exit: 0 everything current · 1 something is stale · 2 cannot determine.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

# Ascend to the brand root rather than counting path levels: this repo is
# checked out at <BB>/release/code/main normally but at
# <BB>/release/code/.worktrees/<branch> in a feature worktree, and a fixed
# ../../.. silently resolves to the wrong directory in the second case.
find_brand_root() {
    local d="$1"
    while [ "${d}" != "/" ]; do
        [ -d "${d}/gateway/code" ] && { printf '%s' "${d}"; return 0; }
        d="$(dirname "${d}")"
    done
    return 1
}
BB="${BURROWEE_ROOT:-$(find_brand_root "${REPO}")}"
[ -n "${BB}" ] || { echo "cut-status: cannot locate the Burrowee root above ${REPO} (set BURROWEE_ROOT)" >&2; exit 2; }

FETCH=1; QUIET=""
for a in "$@"; do
    case "$a" in
        --no-fetch) FETCH="" ;;
        --quiet)    QUIET=1 ;;
    esac
done

# Mirrors release.sh src_for(). The MAPPING is declarative (a path is a path);
# the SET is derived below from versions/.
src_for() {
    case "$1" in
        cli)      printf '%s' "${BURROWEE_SRC_CLI:-${BB}/cli/code/main}" ;;
        gateway)  printf '%s' "${BURROWEE_SRC_GATEWAY:-${BB}/gateway/code/main}" ;;
        edge)     printf '%s' "${BURROWEE_SRC_EDGE:-${BB}/edge/code/main}" ;;
        agent)    printf '%s' "${BURROWEE_SRC_AGENT:-${BB}/agent/code/main}" ;;
        relay)    printf '%s' "${BURROWEE_SRC_RELAY:-${BB}/relay/code/main}" ;;
        burrowee) printf '%s' "${BURROWEE_SRC_DISPATCHER:-${BB}/burrowee/code/main}" ;;
        *)        printf '' ;;
    esac
}

[ -d "${REPO}/versions" ] || { echo "cut-status: no versions/ at ${REPO}" >&2; exit 2; }
components="$(ls "${REPO}/versions" | grep -v '\.stamp$' | sort)"
[ -n "${components}" ] || { echo "cut-status: versions/ is empty" >&2; exit 2; }

stale=0; unknown=0
[ -n "${QUIET}" ] || printf '%-10s %-10s %-10s %-9s %s\n' COMPONENT CUT-AT MAIN STATE UNRELEASED

for c in ${components}; do
    stamp_file="${REPO}/versions/${c}.stamp"
    root="$(src_for "${c}")"

    if [ ! -f "${stamp_file}" ] || [ -z "${root}" ] || [ ! -d "${root}/.git" ]; then
        # A component that is cut but whose source cannot be located is worse
        # than stale: nothing here can tell whether it is behind.
        unknown=$((unknown + 1))
        [ -n "${QUIET}" ] || printf '%-10s %-10s %-10s %-9s %s\n' "${c}" "-" "-" "UNKNOWN" "no stamp or source"
        continue
    fi

    stamp="$(cat "${stamp_file}")"
    release_sha="${stamp##*.}"
    [ -n "${FETCH}" ] && git -C "${root}" fetch origin main -q 2>/dev/null
    head_sha="$(git -C "${root}" rev-parse --short=8 origin/main 2>/dev/null)"

    if [ -z "${head_sha}" ]; then
        unknown=$((unknown + 1))
        [ -n "${QUIET}" ] || printf '%-10s %-10s %-10s %-9s %s\n' "${c}" "${release_sha}" "-" "UNKNOWN" "no origin/main"
    elif [ "${release_sha}" = "${head_sha}" ]; then
        [ -n "${QUIET}" ] || printf '%-10s %-10s %-10s %-9s %s\n' "${c}" "${release_sha}" "${head_sha}" "current" "0"
    else
        stale=$((stale + 1))
        n="$(git -C "${root}" rev-list --count "${release_sha}..origin/main" 2>/dev/null || echo '?')"
        if [ -n "${QUIET}" ]; then
            printf '%s\n' "${c}"
        else
            printf '%-10s %-10s %-10s %-9s %s\n' "${c}" "${release_sha}" "${head_sha}" "STALE" "${n}"
            git -C "${root}" log --oneline "${release_sha}..origin/main" 2>/dev/null | sed 's/^/           /'
        fi
    fi
done

if [ "${unknown}" -gt 0 ]; then
    [ -n "${QUIET}" ] || echo "cut-status: ${unknown} component(s) could not be determined"
    exit 2
fi
[ "${stale}" -eq 0 ] && exit 0
[ -n "${QUIET}" ] || echo "cut-status: ${stale} component(s) have unreleased work"
exit 1
