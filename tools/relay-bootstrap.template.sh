#!/bin/sh
# Burrowee relay outer bootstrap — THE TRUST ANCHOR (POSIX sh, macOS + Linux).
#
#   curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/relay/install.sh \
#     | sh -s -- --key ./relay_dl.key
#
# This is the signing trust-anchor bootstrap for the `relay` component. It is
# DISTINCT from the public cli/gateway/edge bootstrap: every download is gated
# by a challenge-response signed with an operator-provisioned ed25519 private
# key. The operator key must be manually pre-registered on the release host.
#
# Flow:
#   1. Resolve the operator key (--key <pem> or BURROWEE_RELAY_DL_KEY env).
#   2. Compute the key fingerprint once (sha256(raw 32B pubkey)[:16] hex).
#   3. Detect platform (OS/arch).
#   4. For each artifact: GET /relay/challenge → sign nonce:path → gated GET.
#   5. Verify minisign signature on SHA256SUMS.txt (baked pubkey, the same
#      minisign trust anchor used by public components); verify sha256 of zip.
#   6. Abort before installing on any failure.
#   7. Unzip + run inner install.sh.
#   8. Store operator key at ~/.burrowee/relay/release_dl.key (0600) for update.
#
# DO NOT EDIT generated copies (relay/install.sh) by hand — they are produced
# from tools/relay-bootstrap.template.sh by tools/gen-bootstraps.sh.
#
# Env vars:
#   BURROWEE_RELAY_DL_KEY        path to the operator ed25519 PEM private key
#                                (alternative to --key <pem>)
#   BURROWEE_RELAY_VERSION       pin a release stamp (e.g. 20260617120000); default: latest
#   PREFIX                       install root (default $HOME/.local; bins at PREFIX/bin)
#   BURROWEE_UNINSTALL=1         pass through to the inner installer to remove bins
#   BURROWEE_DL_BASE             (test hook) download from this base instead of release.burrowee.com
#   OPENSSL                      override the openssl binary (default: openssl)

set -eu

# ---- knobs --------------------------------------------------------------
COMP="@COMP@"
PUBKEY="@PUBKEY@"
PREFIX="${PREFIX:-$HOME/.local}"
BASE="${BURROWEE_DL_BASE:-https://release.burrowee.com}"
OPENSSL="${OPENSSL:-openssl}"

# Production downloads are pinned to HTTPS/TLS1.2 (--proto =https). The
# BURROWEE_DL_BASE test hook points at a local plain-HTTP server, so when it is
# set we drop the TLS-only flags (they'd reject http://); signed requests are
# still verified against the baked pubkey regardless.
if [ -n "${BURROWEE_DL_BASE:-}" ]; then
    CURL="curl -fsSL --connect-timeout 15 --max-time 300"
else
    CURL="curl -fsSL --proto =https --tlsv1.2 --connect-timeout 15 --max-time 300"
fi

# ---- helpers ------------------------------------------------------------
fail() { printf '\n  ✗ %s\n\n' "$*" >&2; exit 1; }
info() { printf '  → %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }

# ---- parse argv ---------------------------------------------------------
KEY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --key)
            [ $# -ge 2 ] || fail "--key requires a path argument"
            KEY="$2"
            shift 2
            ;;
        --key=*)
            KEY="${1#--key=}"
            shift
            ;;
        *)
            fail "unknown argument: $1 (expected: --key <pem>)"
            ;;
    esac
done

# ---- resolve operator key -----------------------------------------------
# Accept --key <pem> (parsed above) OR the BURROWEE_RELAY_DL_KEY env var.
if [ -z "$KEY" ]; then
    KEY="${BURROWEE_RELAY_DL_KEY:-}"
fi
[ -n "$KEY" ] || fail "operator key required: pass --key <pem> or set BURROWEE_RELAY_DL_KEY"
[ -f "$KEY" ] || fail "operator key not found: $KEY"

# ---- guard against a TEMP / unbaked pubkey ------------------------------
case "$PUBKEY" in
    ""|*REPLACE*|*PLACEHOLDER*|*TEMP*)
        fail "this installer was built without a real signing key — refusing to verify against a placeholder (regenerate with tools/gen-bootstraps.sh)" ;;
esac

# ---- compute fingerprint once -------------------------------------------
# FP = hex(sha256(raw 32-byte ed25519 pubkey))[:16]
# openssl pkey -pubout -outform DER extracts the SubjectPublicKeyInfo DER blob;
# the ed25519 raw key is the trailing 32 bytes of that.
info "computing key fingerprint"
FP="$("$OPENSSL" pkey -in "$KEY" -pubout -outform DER 2>/dev/null \
    | tail -c 32 \
    | "$OPENSSL" dgst -sha256 -binary \
    | xxd -p -c256 \
    | cut -c1-16)" || fail "fingerprint computation failed — is $KEY a valid ed25519 PEM private key?"
[ -n "$FP" ] || fail "fingerprint computation returned empty — check that $KEY is a valid ed25519 PEM private key"
info "key fingerprint: $FP"

# ---- platform detection -------------------------------------------------
case "$(uname -s)" in
    Darwin) OS=darwin ;;
    Linux)  OS=linux ;;
    *)      fail "unsupported OS: $(uname -s) (burrowee relay ships darwin + linux only)" ;;
esac
case "$(uname -m)" in
    arm64|aarch64) ARCH=arm64 ;;
    x86_64|amd64)  ARCH=amd64 ;;
    *)             fail "unsupported arch: $(uname -m) (burrowee relay ships arm64 + amd64 only)" ;;
esac

printf '\n  burrowee %s installer  (%s/%s)\n\n' "$COMP" "$OS" "$ARCH"

# ---- temp workspace -----------------------------------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/burrowee-${COMP}-XXXXXX")" || fail "could not create temp dir"
trap 'rm -rf "$TMP"' EXIT INT TERM

# ---- gated download function --------------------------------------------
# gated_get <path> <local-filename>
#   path      : the request path, e.g. /relay/release/latest.linux-amd64.zip
#   local-filename : written under $TMP
#
# 1. Fetch a single-use nonce from the gate (unauthenticated).
# 2. Sign the exact bytes "nonce:path" with the operator key (ed25519, raw input).
# 3. Send the signed request with the three required headers.
# shellcheck disable=SC2317  # used below after definition
gated_get() {
    _path="$1"
    _out="$2"

    # Challenge: fetch nonce
    # shellcheck disable=SC2086  # $CURL is an intentional space-split command string; POSIX sh has no arrays.
    _nonce="$($CURL "$BASE/relay/challenge" 2>/dev/null \
        | sed -n 's/.*"nonce":"\([^"]*\)".*/\1/p')"
    [ -n "$_nonce" ] || fail "challenge: empty nonce from $BASE/relay/challenge"

    # Sign: nonce:path (raw input, output base64-STD via openssl base64 -A)
    _sig="$(printf '%s' "$_nonce:$_path" \
        | "$OPENSSL" pkeyutl -sign -inkey "$KEY" -rawin 2>/dev/null \
        | "$OPENSSL" base64 -A)" || fail "signing failed — is $KEY a valid ed25519 PEM private key?"
    [ -n "$_sig" ] || fail "signing returned empty signature"

    # Gated fetch: send the three required headers
    # shellcheck disable=SC2086  # $CURL is an intentional space-split command string; POSIX sh has no arrays.
    $CURL \
        -H "X-Burrowee-Key-FP: $FP" \
        -H "X-Burrowee-Nonce: $_nonce" \
        -H "X-Burrowee-Sig: $_sig" \
        -o "$TMP/$_out" \
        "$BASE$_path" \
        || fail "gated download failed: $_path — check that your key is registered on the release host"
}

# ---- version / path resolution ------------------------------------------
# Per-component pin env var (mirrors the public bootstrap pattern).
PIN="${BURROWEE_RELAY_VERSION:-}"

PLAT="${OS}-${ARCH}"
if [ -n "$PIN" ]; then
    info "using pinned version: $PIN"
    ZIP_PATH="/relay/release/${PIN}/latest.${PLAT}.zip"
    SUMS_PATH="/relay/release/${PIN}/SHA256SUMS.txt"
    SIG_PATH="/relay/release/${PIN}/SHA256SUMS.txt.minisig"
else
    ZIP_PATH="/relay/release/latest.${PLAT}.zip"
    SUMS_PATH="/relay/release/SHA256SUMS.txt"
    SIG_PATH="/relay/release/SHA256SUMS.txt.minisig"
fi

ZIP_FILE="latest.${PLAT}.zip"

# ---- download (gated) ---------------------------------------------------
info "downloading relay artifact (gated)"
gated_get "$ZIP_PATH"   "$ZIP_FILE"
info "downloading SHA256SUMS.txt + signature (gated)"
gated_get "$SUMS_PATH"  "SHA256SUMS.txt"
gated_get "$SIG_PATH"   "SHA256SUMS.txt.minisig"

# ---- require minisign ---------------------------------------------------
# minisign is the trust root: it must already be on PATH from a trusted source
# (your package manager). We never auto-fetch the verifier — a binary pulled
# over the network and run unverified would itself become an unverified trust
# root, defeating the whole signature chain. Verification is mandatory.
if command -v minisign >/dev/null 2>&1; then
    MINISIGN=minisign
else
    case "$OS" in
        darwin) hint="brew install minisign" ;;
        *)      hint="apt-get install minisign  (or your distro's package manager)" ;;
    esac
    fail "minisign is required and is not installed — install it and re-run.
    $hint
    upstream: https://github.com/jedisct1/minisign
    Verification is mandatory; this installer will NOT run an unverified verifier."
fi

# ---- VERIFY (the trust gate) --------------------------------------------
info "verifying signature"
# 1) minisign signature over SHA256SUMS.txt, using the baked pubkey (no key fetch)
"$MINISIGN" -V -P "$PUBKEY" -m "$TMP/SHA256SUMS.txt" -x "$TMP/SHA256SUMS.txt.minisig" >/dev/null \
    || fail "signature verification failed — aborting (refusing to install unverified bytes)"
ok "minisign signature valid"

info "verifying checksum"
# 2) the zip's checksum against the now-trusted sums file
grep -qF "$ZIP_FILE" "$TMP/SHA256SUMS.txt" \
    || fail "no checksum entry for $ZIP_FILE — release incomplete or tampered; aborting"
if command -v shasum >/dev/null 2>&1; then
    ( cd "$TMP" && shasum -a 256 -c --ignore-missing SHA256SUMS.txt >/dev/null ) \
        || fail "checksum mismatch — aborting (zip tampered or download corrupted)"
elif command -v sha256sum >/dev/null 2>&1; then
    ( cd "$TMP" && sha256sum -c --ignore-missing SHA256SUMS.txt >/dev/null ) \
        || fail "checksum mismatch — aborting (zip tampered or download corrupted)"
else
    fail "neither shasum nor sha256sum found — cannot verify; aborting"
fi
ok "checksum verified"

# ---- unzip + exec the verified inner installer --------------------------
command -v unzip >/dev/null 2>&1 \
    || fail "unzip not found — install it (\`brew install unzip\` / \`apt-get install unzip\`) and retry"
unzip -q -o "$TMP/$ZIP_FILE" -d "$TMP/x" || fail "zip extraction failed — corrupt download?"
[ -f "$TMP/x/install.sh" ] || fail "release zip missing inner install.sh — aborting"

ok "verified — running inner installer"
# Run with cwd = the unzipped dir: the inner installer resolves the binaries
# relative to its own location.
( cd "$TMP/x" && PREFIX="$PREFIX" BURROWEE_UNINSTALL="${BURROWEE_UNINSTALL:-}" sh ./install.sh )

# ---- store operator key for relay update --------------------------------
# Store the key at the canonical path so `relay update` can find it without
# requiring --key on every invocation.
KEY_DIR="$HOME/.burrowee/relay"
mkdir -p "$KEY_DIR"
cp "$KEY" "$KEY_DIR/release_dl.key"
chmod 600 "$KEY_DIR/release_dl.key"
ok "stored operator key at $KEY_DIR/release_dl.key (for relay update)"
