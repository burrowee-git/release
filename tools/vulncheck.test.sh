#!/usr/bin/env bash
# vulncheck.test.sh — unit tests for tools/vulncheck.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HERE}/vulncheck.sh"

fail=0
check() { # check <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi
}

# --- resolve_release_mode ---------------------------------------------------
check "apple-only"        "$(resolve_release_mode 1 '' '')"  "1|"
check "vulncheck-only"    "$(resolve_release_mode '' 1 '')"  "|1"
check "public (both set)" "$(resolve_release_mode 1 1 '')"   "1|1"
check "prompt yes"        "$(resolve_release_mode '' '' y)"  "1|1"
check "prompt Y"          "$(resolve_release_mode '' '' Y)"  "1|1"
check "prompt no"         "$(resolve_release_mode '' '' n)"  "|"
check "prompt empty"      "$(resolve_release_mode '' '' '')" "|"

[ "${fail}" = 0 ] && echo "ALL OK" || { echo "TESTS FAILED"; exit 1; }
