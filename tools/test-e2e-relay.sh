#!/usr/bin/env bash
# test-e2e-relay.sh — prove the gated relay release channel OFFLINE.
#
# No live host, no real keys. This:
#   1. Generates a temp ed25519 PEM operator key + a temp minisign keypair.
#   2. Builds relay-gate from source.
#   3. Registers the operator pubkey in a temp sqlite registry.
#   4. Creates a fake releases dir (zip + SHA256SUMS.txt + minisig).
#   5. Regenerates relay/install.sh baking the test minisign pubkey.
#   6. Starts relay-gate pointing at the temp registry + releases dir.
#   7. HAPPY PATH: runs the gated relay/install.sh — asserts exit 0,
#      binary installed, operator key stored at 0600.
#   8. UNREGISTERED-KEY PATH: runs with a SECOND unregistered key —
#      asserts non-zero exit and nothing installed (gate returns 401).
#
# Exits 0 only if both paths produce the expected result.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# ---- tool paths (the Burrowee per-dir hook strips /opt/homebrew/bin) ---------
export PATH="/opt/homebrew/bin:${PATH}"
export OPENSSL="/opt/homebrew/bin/openssl"
export MINISIGN="/opt/homebrew/bin/minisign"
GO_BIN="${GO_BIN:-/opt/homebrew/bin/go}"
export GO_BIN

GATE_PORT="${E2E_RELAY_PORT:-8099}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ E2E-RELAY FAILED: %s\n' "$*" >&2; exit 1; }

# ---- workdir + cleanup trap --------------------------------------------------
W="$(mktemp -d "${TMPDIR:-/tmp}/e2e-relay-XXXXXX")"
GATE_PID=""

cleanup() {
    [ -n "${GATE_PID}" ] && kill "${GATE_PID}" 2>/dev/null || true
    rm -rf "${W}"
    # Restore any regenerated bootstraps so the worktree stays clean.
    /usr/bin/git -C "${REPO_ROOT}" checkout -- \
        relay/install.sh cli/install.sh gateway/install.sh edge/install.sh \
        2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---- platform detection (mirrors test-e2e.sh) --------------------------------
case "$(uname -s)" in Darwin) OS=darwin ;; Linux) OS=linux ;; *) die "unsupported OS $(uname -s)" ;; esac
case "$(uname -m)" in arm64|aarch64) ARCH=arm64 ;; x86_64|amd64) ARCH=amd64 ;; *) die "unsupported arch $(uname -m)" ;; esac
PLAT="${OS}-${ARCH}"
say "platform = ${PLAT}"

# ---- (1) generate operator ed25519 PEM keypair in $W -------------------------
say "generating operator ed25519 keypair"
"${OPENSSL}" genpkey -algorithm ed25519 -out "${W}/operator.key" 2>/dev/null
"${OPENSSL}" pkey -in "${W}/operator.key" -pubout -out "${W}/operator.pub" 2>/dev/null

# ---- (2) generate test minisign keypair (no password) -----------------------
say "generating test minisign keypair"
"${MINISIGN}" -G -p "${W}/tm.pub" -s "${W}/tm.key" -W 2>/dev/null

# ---- (3) build relay-gate ---------------------------------------------------
say "building relay-gate"
CGO_ENABLED=0 "${GO_BIN}" build -o "${W}/relay-gate" ./cmd/relay-gate

# ---- (4) register operator pubkey in temp registry --------------------------
say "registering operator pubkey"
REGISTERED_FP="$(OPENSSL="${OPENSSL}" REGISTRY="${W}/reg.db" \
    bash tools/deploy.register.relay.server.sh "${W}/operator.pub" "e2e")"
[ -n "${REGISTERED_FP}" ] || die "register script returned empty fingerprint"
say "registered fingerprint: ${REGISTERED_FP}"

# ---- (5) build fake releases dir $W/releases --------------------------------
say "building fake releases dir"
mkdir -p "${W}/releases"

# Create an inner install.sh that "installs" a dummy burrowee-relay binary.
# The inner installer checks for the binary alongside it inside the unzipped dir.
mkdir -p "${W}/zip-contents"
cat > "${W}/zip-contents/install.sh" <<'INNER_EOF'
#!/bin/sh
set -eu
BIN_DIR="${PREFIX:-$HOME/.local}/bin"
mkdir -p "$BIN_DIR"
install -m 0755 ./burrowee-relay "$BIN_DIR/burrowee-relay"
echo "installed to $BIN_DIR: burrowee-relay"
INNER_EOF
chmod +x "${W}/zip-contents/install.sh"

# Create a minimal dummy binary (just a self-aware script).
cat > "${W}/zip-contents/burrowee-relay" <<'BIN_EOF'
#!/bin/sh
echo "burrowee-relay e2e-test-stub"
BIN_EOF
chmod +x "${W}/zip-contents/burrowee-relay"

# Zip it up into the releases dir as latest.<PLAT>.zip
ZIP_NAME="latest.${PLAT}.zip"
( cd "${W}/zip-contents" && zip -q "${W}/releases/${ZIP_NAME}" install.sh burrowee-relay )

# Compute SHA256SUMS.txt
( cd "${W}/releases" && shasum -a 256 "${ZIP_NAME}" > SHA256SUMS.txt 2>/dev/null ) \
    || ( cd "${W}/releases" && sha256sum "${ZIP_NAME}" > SHA256SUMS.txt )

# Sign SHA256SUMS.txt with the test minisign key
"${MINISIGN}" -S -s "${W}/tm.key" -m "${W}/releases/SHA256SUMS.txt" 2>/dev/null

say "releases dir contents:"
ls -1 "${W}/releases"

# ---- (6) regenerate relay/install.sh baking the test minisign pubkey ---------
say "regenerating relay/install.sh with test minisign pubkey"
BURROWEE_PUBKEY_FILE="${W}/tm.pub" sh tools/gen-bootstraps.sh

# ---- (7) start relay-gate ---------------------------------------------------
say "starting relay-gate on 127.0.0.1:${GATE_PORT}"
"${W}/relay-gate" \
    --listen "127.0.0.1:${GATE_PORT}" \
    --registry "${W}/reg.db" \
    --releases "${W}/releases" \
    &
GATE_PID=$!

# Poll until the challenge endpoint responds (up to 10 s).
i=0
until curl -fsS "http://127.0.0.1:${GATE_PORT}/relay/challenge" -o /dev/null 2>/dev/null; do
    i=$((i+1)); [ "${i}" -lt 100 ] || die "relay-gate did not come up on port ${GATE_PORT}"
    sleep 0.1
done
say "relay-gate up (PID ${GATE_PID})"

# ---- (8) HAPPY PATH ---------------------------------------------------------
say "HAPPY PATH — installing via gated relay/install.sh"
HAPPY_HOME="${W}/home"
HAPPY_PREFIX="${W}/prefix"
mkdir -p "${HAPPY_HOME}"

PATH="/opt/homebrew/bin:${PATH}" \
OPENSSL="${OPENSSL}" \
BURROWEE_DL_BASE="http://127.0.0.1:${GATE_PORT}" \
PREFIX="${HAPPY_PREFIX}" \
HOME="${HAPPY_HOME}" \
    sh "${REPO_ROOT}/relay/install.sh" --key "${W}/operator.key" \
    || die "happy-path install exited non-zero (expected success)"

# Assert the binary landed in prefix/bin
INSTALLED_BIN="${HAPPY_PREFIX}/bin/burrowee-relay"
[ -x "${INSTALLED_BIN}" ] || die "burrowee-relay not found at ${INSTALLED_BIN}"
say "binary installed at ${INSTALLED_BIN}"

# Assert the operator key was stored at 0600
STORED_KEY="${HAPPY_HOME}/.burrowee/relay/release_dl.key"
[ -f "${STORED_KEY}" ] || die "stored key not found at ${STORED_KEY}"
KEY_PERMS="$(stat -f '%OLp' "${STORED_KEY}" 2>/dev/null || stat -c '%a' "${STORED_KEY}")"
[ "${KEY_PERMS}" = "600" ] || die "stored key has mode ${KEY_PERMS}, expected 600"
say "operator key stored at ${STORED_KEY} (mode 600)"

printf '\nHAPPY-PATH OK\n'

# ---- (9) UNREGISTERED-KEY PATH (must fail) -----------------------------------
say "UNREGISTERED-KEY PATH — generating second key (NOT in registry)"
"${OPENSSL}" genpkey -algorithm ed25519 -out "${W}/unreg.key" 2>/dev/null

UNREG_PREFIX="${W}/unreg-prefix"
mkdir -p "${UNREG_PREFIX}"

set +e
PATH="/opt/homebrew/bin:${PATH}" \
OPENSSL="${OPENSSL}" \
BURROWEE_DL_BASE="http://127.0.0.1:${GATE_PORT}" \
PREFIX="${UNREG_PREFIX}" \
HOME="${W}/unreg-home" \
    sh "${REPO_ROOT}/relay/install.sh" --key "${W}/unreg.key"
UNREG_RC=$?
set -e

if [ "${UNREG_RC}" -eq 0 ]; then
    die "unregistered-key install returned 0 — gate FAILED to reject"
fi
if [ -e "${UNREG_PREFIX}/bin/burrowee-relay" ]; then
    die "unregistered-key install left a binary — gate FAILED to stop install"
fi
say "unregistered-key install aborted with rc=${UNREG_RC} and installed nothing"
printf '\nUNREGISTERED-KEY-REJECTED OK\n'

printf '\n✓ ALL OK\n'
