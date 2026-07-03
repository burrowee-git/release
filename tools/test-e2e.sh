#!/usr/bin/env bash
# test-e2e.sh — prove the whole release chain OFFLINE with the TEST key.
#
# No GitHub, no nsm. This:
#   1. dry-run-builds the cli release (signed by the TEST key) into dist/<stamp>/.
#   2. regenerates the outer bootstraps (baking the TEST pubkey).
#   3. serves dist/<stamp>/ over a local http.server.
#   4. HAPPY PATH: runs the real outer bootstrap against the local server and
#      asserts the installed `burrowee-cli` reports the expected stamp.
#   5. TAMPER PATH: flips one byte inside the served zip, reruns the SAME
#      install, and asserts it ABORTS non-zero AND installs nothing.
#
# Exits 0 only if BOTH "HAPPY-PATH OK" and "TAMPER-ABORTED OK" print.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# go on PATH (the Burrowee per-dir hook strips /opt/homebrew/bin) ---------------
GO_BIN="${GO_BIN:-go}"
command -v "${GO_BIN}" >/dev/null 2>&1 || GO_BIN=/opt/homebrew/bin/go
export GO_BIN

# component source dirs — build from main checkout --------------------------------
export BURROWEE_SRC_CLI="${BURROWEE_SRC_CLI:-/Volumes/MacintoshED/Workstation/Coding/Burrowee/cli/code/cli}"
export BURROWEE_SRC_DISPATCHER="${BURROWEE_SRC_DISPATCHER:-/Volumes/MacintoshED/Workstation/Coding/Burrowee/burrowee/code/burrowee}"

COMP=cli
PORT="${E2E_PORT:-8731}"
HAPPY_PREFIX="${TMPDIR:-/tmp}/e2e-prefix"
TAMPER_PREFIX="${TMPDIR:-/tmp}/e2e-prefix-tamper"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ E2E FAILED: %s\n' "$*" >&2; exit 1; }

# ---- cleanup trap -----------------------------------------------------------
SERVER_PID=""
cleanup() {
    [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

rm -rf "${HAPPY_PREFIX}" "${TAMPER_PREFIX}"

# ---- (1) dry-run build (signed by the TEST key) -----------------------------
say "release.sh ${COMP} --dry-run (TEST-key signed build)"
bash tools/release.sh "${COMP}" --dry-run

# ---- capture the stamp / serve dir ------------------------------------------
# The stamp is the single freshly-written dist/<stamp>/ that holds the cli zips.
STAMP="$(SRC_DIR="${BURROWEE_SRC_CLI}" bash tools/version.sh "${COMP}" --stamp)"
SERVE_DIR="${REPO_ROOT}/dist/${STAMP}"
[ -d "${SERVE_DIR}" ] || die "expected dist dir not found: ${SERVE_DIR}"
PIN="${COMP}/${STAMP}"
say "stamp = ${STAMP}  (pin = ${PIN})"

# resolve which zip this host needs (the one the bootstrap will request)
case "$(uname -s)" in Darwin) OS=darwin ;; Linux) OS=linux ;; *) die "unsupported OS $(uname -s)" ;; esac
case "$(uname -m)" in arm64|aarch64) ARCH=arm64 ;; x86_64|amd64) ARCH=amd64 ;; *) die "unsupported arch $(uname -m)" ;; esac
ZIP="burrowee-${COMP}-${OS}-${ARCH}.zip"
[ -f "${SERVE_DIR}/${ZIP}" ] || die "host zip not present: ${SERVE_DIR}/${ZIP}"

# ---- (3) regenerate bootstraps with the TEST pubkey -------------------------
say "gen-bootstraps.sh (bake TEST pubkey)"
BURROWEE_PUBKEY_FILE="${REPO_ROOT}/tools/testkeys/test.pub" sh tools/gen-bootstraps.sh

# ---- (4) serve dist/<stamp>/ over http --------------------------------------
say "serving ${SERVE_DIR} on 127.0.0.1:${PORT}"
( cd "${SERVE_DIR}" && exec python3 -m http.server "${PORT}" --bind 127.0.0.1 ) >/dev/null 2>&1 &
SERVER_PID=$!

# wait for the server to answer
i=0
until curl -fsS "http://127.0.0.1:${PORT}/${ZIP}" -o /dev/null 2>/dev/null; do
    i=$((i+1)); [ "${i}" -lt 50 ] || die "http server did not come up on ${PORT}"
    sleep 0.1
done
say "server up (serving ${ZIP})"

# the exact install invocation, reused by both paths (only PREFIX differs) -----
DL_BASE="http://127.0.0.1:${PORT}"
run_install() {
    # run_install <prefix>  — runs the real outer bootstrap against local server.
    # Skip preflight: this E2E exercises the trust gate, and the local server
    # serves only the release assets, not a preflight.sh.
    BURROWEE_DL_BASE="${DL_BASE}" \
    BURROWEE_CLI_VERSION="${PIN}" \
    BURROWEE_SKIP_PREFLIGHT=1 \
    PREFIX="$1" \
        sh "${REPO_ROOT}/${COMP}/install.sh"
}

# ---- (5) HAPPY PATH ---------------------------------------------------------
say "HAPPY PATH — install into ${HAPPY_PREFIX}"
run_install "${HAPPY_PREFIX}" || die "happy-path install exited non-zero (expected success)"

INSTALLED_BIN="${HAPPY_PREFIX}/bin/burrowee-cli"
[ -x "${INSTALLED_BIN}" ] || die "burrowee-cli not installed at ${INSTALLED_BIN}"
GOT="$("${INSTALLED_BIN}" version 2>&1 || true)"
say "installed burrowee-cli version → ${GOT}"
case "${GOT}" in
    *"${STAMP}"*) printf '\nHAPPY-PATH OK\n' ;;
    *) die "version mismatch: expected stamp '${STAMP}' in output, got: ${GOT}" ;;
esac

# release-guard: the shipped gateway binary must carry no config/env literals.
GW_SRC="${BURROWEE_SRC_GATEWAY:-/Volumes/MacintoshED/Workstation/Coding/Burrowee/gateway/code/gateway}"
GW_BIN="${TMPDIR:-/tmp}/e2e-gateway-bin"
( cd "${GW_SRC}" && CGO_ENABLED=0 "${GO_BIN}" build -trimpath -o "${GW_BIN}" ./cmd/burrowee-gateway )
"${REPO_ROOT}/tools/verify-no-env.sh" "${GW_BIN}"
rm -f "${GW_BIN}"
echo "ENV-GUARD OK"

# ---- (6) TAMPER PATH --------------------------------------------------------
say "TAMPER PATH — flip one byte inside the served ${ZIP}"
ZIP_PATH="${SERVE_DIR}/${ZIP}"
BACKUP="${ZIP_PATH}.orig"
cp "${ZIP_PATH}" "${BACKUP}"
restore_zip() { [ -f "${BACKUP}" ] && mv -f "${BACKUP}" "${ZIP_PATH}" || true; }

# flip a byte well inside the compressed payload (offset 256), in place.
# python keeps it portable + verifiable (read old byte, xor 0xFF, write back).
python3 - "${ZIP_PATH}" <<'PY'
import sys
p = sys.argv[1]
off = 256
with open(p, "r+b") as f:
    f.seek(off)
    b = f.read(1)
    if not b:
        raise SystemExit("zip too small to tamper at offset %d" % off)
    f.seek(off)
    f.write(bytes([b[0] ^ 0xFF]))
print("flipped byte at offset %d (0x%02x -> 0x%02x)" % (off, b[0], b[0] ^ 0xFF))
PY

say "TAMPER PATH — rerun the SAME install into ${TAMPER_PREFIX} (must abort)"
set +e
run_install "${TAMPER_PREFIX}"
RC=$?
set -e

restore_zip

if [ "${RC}" -eq 0 ]; then
    die "tampered install returned 0 — verification gate FAILED to abort"
fi
if [ -e "${TAMPER_PREFIX}/bin/burrowee-cli" ]; then
    die "tampered install left a binary at ${TAMPER_PREFIX}/bin/burrowee-cli — must install nothing"
fi
say "tampered install aborted with rc=${RC} and installed nothing"
printf '\nTAMPER-ABORTED OK\n'

printf '\n✓ E2E PASSED (happy path + tamper-abort)\n'
