#!/usr/bin/env bash
# build-legacy.test.sh — proves tools/build.sh VARIANT=legacy (spec §4.2, §12).
#
# Three properties, in order:
#   1. VARIANT= (stock) output for COMP=agent still imports the macOS-12 symbol
#      (_SecTrustCopyCertificateChain) — this is the spec §12 build-scoping proof:
#      the overlay must be scoped to the variant, never applied globally.
#   2. VARIANT=legacy output for the same component passes assert_legacy_symbols
#      (tools/legacy/darwin/symbols.sh) — the overlay actually applied.
#   3. VARIANT=legacy TARGETARCH=arm64 refuses before building, with "legacy
#      variant is darwin/amd64 only" on stderr and a non-zero exit.
#
# Builds from the agent component's OWN main worktree (COMP=agent is the
# smallest component; it links crypto/x509) into temp OUT_DIRs — never into
# the agent worktree itself. See tools/test-build-gowork.sh for the same
# env-var / MAP invocation shape this test copies.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_SRC="${BURROWEE_SRC_AGENT:-/Volumes/MacintoshED/Workstation/Coding/Burrowee/agent/code/agent}"

GO_BIN="${GO_BIN:-go}"
command -v "${GO_BIN}" >/dev/null 2>&1 || GO_BIN=/opt/homebrew/bin/go
command -v "${GO_BIN}" >/dev/null 2>&1 || { echo "✗ go not found on PATH or /opt/homebrew/bin/go" >&2; exit 1; }

[ -d "${AGENT_SRC}" ] || { echo "✗ agent main worktree not found at ${AGENT_SRC}" >&2; exit 1; }

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-build-legacy-XXXXXX")"
trap 'rm -rf "${W}"' EXIT INT TERM

STAMP="v0.0.0.2026.01.01.deadbeef"

# ---- 1: stock build still imports the macOS-12 symbol -----------------------
STOCK_OUT="${W}/stock"
if ! COMP=agent SRC_DIR="${AGENT_SRC}" TARGETOS=darwin TARGETARCH=amd64 \
     STAMP="${STAMP}" OUT_DIR="${STOCK_OUT}" GO_BIN="${GO_BIN}" \
     bash "${REPO_ROOT}/tools/build.sh" > "${W}/stock.log" 2>&1; then
    sed 's/^/    /' "${W}/stock.log" >&2
    echo "FAIL: stock (VARIANT=) build failed" >&2
    fail=1
fi
stock_bin="${STOCK_OUT}/burrowee-agent"
if [ -f "${stock_bin}" ]; then
    stock_syms="$(nm -u "${stock_bin}" 2>/dev/null | grep -c '^_SecTrustCopyCertificateChain$' || true)"
else
    stock_syms="<no binary>"
fi
check "stock build has the macOS-12 symbol" "${stock_syms}" "1"

# ---- 2: VARIANT=legacy output passes assert_legacy_symbols ------------------
LEGACY_OUT="${W}/legacy"
if ! COMP=agent SRC_DIR="${AGENT_SRC}" TARGETOS=darwin TARGETARCH=amd64 \
     STAMP="${STAMP}" OUT_DIR="${LEGACY_OUT}" GO_BIN="${GO_BIN}" VARIANT=legacy \
     bash "${REPO_ROOT}/tools/build.sh" > "${W}/legacy.log" 2>&1; then
    sed 's/^/    /' "${W}/legacy.log" >&2
    echo "FAIL: legacy (VARIANT=legacy) build failed" >&2
    fail=1
fi
legacy_bin="${LEGACY_OUT}/burrowee-agent"
if [ -f "${legacy_bin}" ]; then
    # shellcheck source=tools/legacy/darwin/symbols.sh
    source "${REPO_ROOT}/tools/legacy/darwin/symbols.sh"
    assert_legacy_symbols "${legacy_bin}" >/dev/null 2>&1
    legacy_status="$?"
else
    legacy_status="<no binary>"
fi
check "legacy build passes assert_legacy_symbols" "${legacy_status}" "0"

# ---- 3: VARIANT=legacy TARGETARCH=arm64 refuses before building -------------
ARM_OUT="${W}/arm64"
COMP=agent SRC_DIR="${AGENT_SRC}" TARGETOS=darwin TARGETARCH=arm64 \
    STAMP="${STAMP}" OUT_DIR="${ARM_OUT}" GO_BIN="${GO_BIN}" VARIANT=legacy \
    bash "${REPO_ROOT}/tools/build.sh" > "${W}/arm64.log" 2> "${W}/arm64.err"
arm_status="$?"
check "VARIANT=legacy arm64 exits non-zero" "$([ "${arm_status}" -ne 0 ] && echo yes || echo no)" "yes"
arm_msg="$(grep -c 'legacy variant is darwin/amd64 only' "${W}/arm64.err" || true)"
check "VARIANT=legacy arm64 stderr names the refusal" "${arm_msg}" "1"

exit "${fail}"
