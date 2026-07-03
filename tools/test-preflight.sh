#!/usr/bin/env bash
# test-preflight.sh — offline checks for the per-component preflight + its pin.
#
# Deterministic (no host-tool dependence): it does NOT assert which packages
# install (that depends on what's already on the box) — it asserts the per-comp
# nginx gate, the dry-run structure under a faked package manager, the
# SKIP_NGINX knob, and that install.sh's baked @PREFLIGHT_SHA256@ matches the
# generated preflight. Prints `PREFLIGHT-TEST OK` on success.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ PREFLIGHT-TEST FAILED: %s\n' "$*" >&2; exit 1; }

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else die "no shasum/sha256sum"; fi
}

# ---- (1) regenerate with the TEST pubkey so preflight.sh files exist --------
say "gen-bootstraps.sh (TEST pubkey)"
BURROWEE_PUBKEY_FILE="${REPO_ROOT}/tools/testkeys/test.pub" sh tools/gen-bootstraps.sh

for f in cli/preflight.sh gateway/preflight.sh edge/preflight.sh; do
    [ -f "${f}" ] || die "expected generated ${f}"
done

# ---- (2) per-comp nginx gate ------------------------------------------------
say "nginx gate: edge=1, cli/gateway=0"
grep -q 'NGINX="1"' edge/preflight.sh    || die "edge/preflight.sh should bake NGINX=\"1\""
grep -q 'NGINX="0"' cli/preflight.sh     || die "cli/preflight.sh should bake NGINX=\"0\""
grep -q 'NGINX="0"' gateway/preflight.sh || die "gateway/preflight.sh should bake NGINX=\"0\""

# ---- (3) dry-run structure under a faked apt-get ----------------------------
say "dry-run edge preflight with a faked apt-get"
SHIM="$(mktemp -d "${TMPDIR:-/tmp}/pf-shim-XXXXXX")"
trap 'rm -rf "${SHIM}"' EXIT
printf '#!/bin/sh\necho "fake-apt $*"\n' > "${SHIM}/apt-get"
chmod +x "${SHIM}/apt-get"
out="$(PATH="${SHIM}:${PATH}" BURROWEE_PREFLIGHT_DRY=1 sh edge/preflight.sh 2>&1)" \
    || die "dry-run edge preflight exited non-zero"
printf '%s\n' "${out}" | grep -q 'package manager: apt'        || die "expected apt detection; got:\n${out}"
printf '%s\n' "${out}" | grep -q 'default: nginx + stream'      || die "expected nginx group for edge; got:\n${out}"

# ---- (4) SKIP_NGINX drops the nginx group -----------------------------------
say "BURROWEE_SKIP_NGINX=1 drops the nginx group"
out_skip="$(PATH="${SHIM}:${PATH}" BURROWEE_PREFLIGHT_DRY=1 BURROWEE_SKIP_NGINX=1 sh edge/preflight.sh 2>&1)" \
    || die "skip-nginx dry-run exited non-zero"
printf '%s\n' "${out_skip}" | grep -q 'default: nginx + stream' \
    && die "nginx group should be skipped under BURROWEE_SKIP_NGINX=1"

# ---- (5) install.sh pins the generated preflight ----------------------------
say "edge/install.sh @PREFLIGHT_SHA256@ matches sha256(edge/preflight.sh)"
baked="$(grep -E '^PREFLIGHT_SHA256=' edge/install.sh | sed -E 's/^PREFLIGHT_SHA256="([^"]*)".*/\1/')"
actual="$(sha256_of edge/preflight.sh)"
[ -n "${baked}" ] || die "no PREFLIGHT_SHA256 baked in edge/install.sh"
[ "${baked}" = "${actual}" ] || die "pin mismatch: baked=${baked} actual=${actual}"

printf '\nPREFLIGHT-TEST OK\n'
