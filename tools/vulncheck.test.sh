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

# --- vulncheck_scan_dirs ----------------------------------------------------
SRC_CLI=/tmp/src-cli SRC_GATEWAY=/tmp/src-gw SRC_EDGE=/tmp/src-edge
SRC_AGENT=/tmp/src-agent SRC_RELAY=/tmp/src-relay SRC_DISPATCHER=/tmp/src-disp
src_for() { case "$1" in
    cli) printf '%s' "$SRC_CLI";; gateway) printf '%s' "$SRC_GATEWAY";;
    edge) printf '%s' "$SRC_EDGE";; agent) printf '%s' "$SRC_AGENT";;
    relay) printf '%s' "$SRC_RELAY";; esac; }

COMPONENTS=(cli gateway)
got="$(vulncheck_scan_dirs | tr '\t' '=' | paste -sd, -)"
check "scan-dirs public" "${got}" "cli=/tmp/src-cli,gateway=/tmp/src-gw,burrowee=/tmp/src-disp"

COMPONENTS=(relay)
got="$(vulncheck_scan_dirs | tr '\t' '=' | paste -sd, -)"
check "scan-dirs relay" "${got}" "relay=/tmp/src-relay,relay-cli=/tmp/src-relay/cli,burrowee=/tmp/src-disp"

# --- vulncheck_gate (stubbed govulncheck) -----------------------------------
REPO_ROOT="$(mktemp -d)"; trap 'rm -rf "${REPO_ROOT}"' EXIT
STUB_DIR="$(mktemp -d)"
mkdir -p /tmp/src-cli /tmp/src-disp

# clean stub → gate passes
cat > "${STUB_DIR}/govulncheck" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${STUB_DIR}/govulncheck"
COMPONENTS=(cli)
if VULNCHECK=1 GOVULNCHECK="${STUB_DIR}/govulncheck" bash -c '
    source '"${HERE}"'/vulncheck.sh
    SRC_CLI=/tmp/src-cli SRC_DISPATCHER=/tmp/src-disp
    src_for() { [ "$1" = cli ] && printf /tmp/src-cli; }
    COMPONENTS=(cli); REPO_ROOT='"${REPO_ROOT}"'
    vulncheck_gate'; then echo "ok: gate clean passes"; else echo "FAIL: gate clean rejected"; fail=1; fi

# finding stub (exit 3) → gate aborts nonzero
cat > "${STUB_DIR}/govulncheck" <<'STUB'
#!/usr/bin/env bash
echo "Vulnerability #1: GO-2099-9999"; exit 3
STUB
chmod +x "${STUB_DIR}/govulncheck"
if VULNCHECK=1 GOVULNCHECK="${STUB_DIR}/govulncheck" bash -c '
    source '"${HERE}"'/vulncheck.sh
    SRC_CLI=/tmp/src-cli SRC_DISPATCHER=/tmp/src-disp
    src_for() { [ "$1" = cli ] && printf /tmp/src-cli; }
    COMPONENTS=(cli); REPO_ROOT='"${REPO_ROOT}"'
    vulncheck_gate' 2>/dev/null; then echo "FAIL: gate passed a finding"; fail=1; else echo "ok: gate aborts on finding"; fi
[ -s "${REPO_ROOT}/dist/vulncheck/cli.txt" ] && echo "ok: report written" || { echo "FAIL: no report"; fail=1; }

[ "${fail}" = 0 ] && echo "ALL OK" || { echo "TESTS FAILED"; exit 1; }
