#!/usr/bin/env bash
# prune-releases.sh — keep only the newest N releases per component on the
# Burrowee release repo, ON ONE CHANNEL; delete the older GitHub Releases AND
# their git tags.
#
# Usage:
#   tools/prune-releases.sh            # DRY-RUN (default): list what would be deleted
#   tools/prune-releases.sh --execute  # actually delete
#
# Env (optional):
#   CHANNEL                 stable|beta (default stable)
#   KEEP                    newest versions to retain per component
#                           (default 10 on stable, 5 on beta)
#   COMPONENTS              space-separated set (default: PUBLIC_COMPONENTS,
#                           tools/public_components.sh; relay is excluded — it
#                           has no GitHub release)
#   BURROWEE_RELEASE_REPO   GitHub repo (default burrowee-git/release)
#
# Per component it lists the release tags matching CHANNEL's anchored pattern
# (spec §4.1 — stable never contains ".beta.", beta always does, so the same
# tag can never be counted on both channels), version-sorts them with
# `sort -V` (so v0.1.12 > v0.1.9), keeps the highest KEEP, and deletes the rest
# via `gh release delete --cleanup-tag` (removes the Release AND the tag). gh
# runs through ghp so the per-repo burrowee-git token is used. A stable prune
# never counts or deletes a beta tag, and a beta prune never counts or deletes
# a stable one.
set -euo pipefail
# The Burrowee per-dir PATH hook strips /opt/homebrew/bin; re-add a sane PATH so
# grep/sort/sed/tr + gh/ghp resolve.
export PATH="/usr/bin:/bin:/opt/homebrew/bin:${HOME}/.claude/bin:${PATH}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/public_components.sh
source "${HERE}/public_components.sh"

REPO="${BURROWEE_RELEASE_REPO:-burrowee-git/release}"
CHANNEL="${CHANNEL:-stable}"
case "${CHANNEL}" in
  stable|beta) ;;
  *) echo "✗ CHANNEL must be stable or beta (got '${CHANNEL}')" >&2; exit 2 ;;
esac
if [ "${CHANNEL}" = beta ]; then
  KEEP="${KEEP:-5}"
else
  KEEP="${KEEP:-10}"
fi
COMPONENTS="${COMPONENTS:-${PUBLIC_COMPONENTS}}"

EXECUTE=0
for a in "$@"; do
  case "$a" in
    --execute|--yes) EXECUTE=1 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown argument: $a" >&2; exit 2 ;;
  esac
done

GHP="$(command -v ghp || echo "${HOME}/bin/ghp")"
[ -x "$GHP" ] || { echo "✗ ghp not found at ${GHP}" >&2; exit 1; }

mode="DRY-RUN"; [ "$EXECUTE" = 1 ] && mode="EXECUTE"
echo "repo=${REPO}  channel=${CHANNEL}  keep=${KEEP}  components=[${COMPONENTS}]  mode=${mode}"
echo

# One API pass; --paginate walks every page so nothing is missed past page 1.
tags="$("$GHP" api "repos/${REPO}/releases" --paginate --jq '.[].tag_name')"

planned=0
for comp in ${COMPONENTS}; do
  # Anchored per spec §4.1 — a tag matching neither channel's pattern is
  # ignored here, same as everywhere else that consumes these tags.
  if [ "${CHANNEL}" = beta ]; then
    pattern="^${comp}/v[0-9]+\.[0-9]+\.[0-9]+\.beta\.[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9a-f]{8}\$"
  else
    pattern="^${comp}/v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9a-f]{8}\$"
  fi
  sorted="$(printf '%s\n' "${tags}" | grep -E "${pattern}" | sort -V || true)"
  if [ -z "${sorted}" ]; then
    echo "[${comp}] no releases"
    continue
  fi
  n="$(printf '%s\n' "${sorted}" | grep -c . || true)"
  if [ "${n}" -le "${KEEP}" ]; then
    echo "[${comp}] ${n} release(s) ≤ keep=${KEEP} — nothing to prune"
    continue
  fi
  drop="$(( n - KEEP ))"
  echo "[${comp}] ${n} releases → keep newest ${KEEP}, remove ${drop}"
  echo "  keep:   $(printf '%s\n' "${sorted}" | tail -n "${KEEP}" | tr '\n' ' ')"
  printf '%s\n' "${sorted}" | head -n "${drop}" | while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    if [ "${EXECUTE}" = 1 ]; then
      if "$GHP" release delete "${tag}" -R "${REPO}" --yes --cleanup-tag >/dev/null 2>&1; then
        echo "  ✓ deleted ${tag}"
      else
        echo "  ✗ FAILED to delete ${tag}"
      fi
    else
      echo "  - would delete ${tag}"
    fi
  done
  planned="$(( planned + drop ))"
done

echo
if [ "${EXECUTE}" = 1 ]; then
  echo "✓ done — removed up to ${planned} release(s); kept newest ${KEEP} per component."
else
  echo "DRY-RUN: ${planned} release(s) would be removed. Re-run with --execute to apply."
fi
