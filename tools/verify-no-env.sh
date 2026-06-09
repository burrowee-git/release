#!/usr/bin/env bash
# verify-no-env.sh — fail if a built Burrowee binary still embeds a forbidden
# config/env runtime literal. The unified-bootstrap design (2026-06-09 §E/§G)
# strips all BURROWEE_* config/identity/path env; the reported
# `missing required env BURROWEE_RELAY_WS` fatal came from a pre-zero-config
# build. This is the release-channel guard: run it on every freshly built
# component binary before publishing.
#
# Usage: verify-no-env.sh <binary> [<binary> ...]
# Forbidden literals (runtime strings, not doc comments — those are stripped):
#   BURROWEE_RELAY_WS   the env that produced the operator's fatal
#   mustEnv             the helper that fatals on a missing required env
#   BURROWEE_GW_        any gateway config/path env (db/keys/hostname/console/…)
# Exit 0 = clean; 1 = a forbidden literal is present; 2 = usage/strings error.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: verify-no-env.sh <binary> [<binary> ...]" >&2; exit 2; }
command -v strings >/dev/null 2>&1 || { echo "✗ 'strings' not found" >&2; exit 2; }

FORBIDDEN='BURROWEE_RELAY_WS|mustEnv|BURROWEE_GW_'
rc=0
for bin in "$@"; do
    [ -f "${bin}" ] || { echo "✗ not a file: ${bin}" >&2; exit 2; }
    hits="$(strings "${bin}" | grep -E -c "${FORBIDDEN}" || true)"
    if [ "${hits}" -ne 0 ]; then
        echo "✗ ${bin}: ${hits} forbidden env literal(s):" >&2
        strings "${bin}" | grep -E -n "${FORBIDDEN}" | sed 's/^/    /' >&2
        rc=1
    else
        echo "✓ ${bin}: no forbidden env literals"
    fi
done
exit "${rc}"
