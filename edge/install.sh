#!/bin/sh
# Burrowee outer bootstrap — THE TRUST ANCHOR (POSIX sh, macOS + Linux).
#
#   curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/edge/install.sh | sh
#
# This is the stable, curl'd-alone entry point for the `edge` component
# (which bundles the `burrowee` dispatcher). It NEVER runs an unverified byte:
# it downloads the release zip + SHA256SUMS.txt + its minisig, verifies the
# minisign signature with a baked-in PUBLIC key, verifies the zip's sha256
# against the now-trusted sums file, and ONLY THEN unzips and execs the inner
# per-release install.sh. Any failure aborts before anything is installed.
#
# DO NOT EDIT generated copies (edge/install.sh) by hand — they are produced
# from tools/bootstrap.template.sh by tools/gen-bootstraps.sh.
#
# Env vars:
#   BURROWEE_<COMP>_VERSION      pin a release tag (e.g. edge/v0.1.0.…); default: latest
#                                (<COMP> = the component name upper-cased, e.g. BURROWEE_CLI_VERSION)
#   PREFIX                       install root (default $HOME/.local; bins at PREFIX/bin)
#   BURROWEE_UNINSTALL=1         pass through to the inner installer to remove bins
#   BURROWEE_RELEASE_REPO        GitHub repo serving releases (default burrowee-git/release)
#   BURROWEE_DL_BASE             (test hook) download assets from this base instead of GitHub

set -eu

# ---- knobs --------------------------------------------------------------
COMP="edge"
PUBKEY="RWQspcYOi6NXeZYBXk1hiSCavFes9WXajHrWFz/b3oWxej9AZQedmS0B"
REPO="${BURROWEE_RELEASE_REPO:-burrowee-git/release}"
PREFIX="${PREFIX:-$HOME/.local}"
DL_BASE="${BURROWEE_DL_BASE:-}"           # test hook (undocumented to users)
VER_ENV="BURROWEE_$(printf '%s' "$COMP" | tr 'a-z' 'A-Z')_VERSION"

CURL="curl -fsSL --proto =https --tlsv1.2 --connect-timeout 15 --max-time 300"

# ---- helpers ------------------------------------------------------------
fail() { printf '\n  ✗ %s\n\n' "$*" >&2; exit 1; }
info() { printf '  → %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }

# ---- platform detection -------------------------------------------------
case "$(uname -s)" in
    Darwin) OS=darwin ;;
    Linux)  OS=linux ;;
    *)      fail "unsupported OS: $(uname -s) (burrowee ships darwin + linux only)" ;;
esac
case "$(uname -m)" in
    arm64|aarch64) ARCH=arm64 ;;
    x86_64|amd64)  ARCH=amd64 ;;
    *)             fail "unsupported arch: $(uname -m) (burrowee ships arm64 + amd64 only)" ;;
esac

printf '\n  burrowee %s installer  (%s/%s)\n\n' "$COMP" "$OS" "$ARCH"

# ---- guard against a TEMP / unbaked pubkey ------------------------------
case "$PUBKEY" in
    ""|*REPLACE*|*PLACEHOLDER*|*TEMP*)
        fail "this installer was built without a real signing key — refusing to verify against a placeholder (regenerate with tools/gen-bootstraps.sh)" ;;
esac

# ---- temp workspace -----------------------------------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/burrowee-${COMP}-XXXXXX")" || fail "could not create temp dir"
trap 'rm -rf "$TMP"' EXIT INT TERM

# ---- version resolution -------------------------------------------------
# Indirect-expand the per-component pin env var without bashisms.
PIN="$(eval "printf '%s' \"\${$VER_ENV:-}\"")"
if [ -n "$PIN" ]; then
    TAG="$PIN"
    info "using pinned version: $TAG"
else
    info "resolving latest ${COMP} release"
    api="https://api.github.com/repos/${REPO}/releases?per_page=100"
    # newest-first list; the FIRST tag matching "<comp>/v" is that component's latest.
    TAG="$($CURL "$api" 2>/dev/null \
        | grep '"tag_name"' \
        | sed -E 's/.*"tag_name" *: *"([^"]+)".*/\1/' \
        | grep -E "^${COMP}/v" \
        | head -n1)" || true
    [ -n "$TAG" ] || fail "no published release found for ${COMP} on ${REPO}"
    info "latest: $TAG"
fi

# ---- download -----------------------------------------------------------
if [ -n "$DL_BASE" ]; then
    BASE="$DL_BASE"
else
    BASE="https://github.com/${REPO}/releases/download/${TAG}"
fi
ZIP="burrowee-${COMP}-${OS}-${ARCH}.zip"

dl() {
    # dl <remote-name> <local-name>  (local goes under $TMP)
    $CURL -o "$TMP/$2" "$BASE/$1" \
        || fail "download failed: $1 (from $BASE) — refusing to install unverified bytes"
}
info "downloading $ZIP"
dl "$ZIP" "$ZIP"
info "downloading SHA256SUMS.txt + signature"
dl "SHA256SUMS.txt"         "SHA256SUMS.txt"
dl "SHA256SUMS.txt.minisig" "SHA256SUMS.txt.minisig"

# ---- ensure minisign ----------------------------------------------------
MINISIGN=""
if command -v minisign >/dev/null 2>&1; then
    MINISIGN=minisign
else
    info "minisign not found — attempting install (verification is mandatory)"
    if [ "$OS" = darwin ] && command -v brew >/dev/null 2>&1; then
        brew install minisign >/dev/null 2>&1 && command -v minisign >/dev/null 2>&1 && MINISIGN=minisign
    elif [ "$OS" = linux ] && command -v apt-get >/dev/null 2>&1; then
        if [ "$(id -u)" = 0 ]; then SUDO=""; elif command -v sudo >/dev/null 2>&1; then SUDO=sudo; else SUDO=""; fi
        DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y minisign >/dev/null 2>&1 \
            && command -v minisign >/dev/null 2>&1 && MINISIGN=minisign
    fi
    if [ -z "$MINISIGN" ]; then
        # last resort: official static linux build over HTTPS into the temp dir
        if [ "$OS" = linux ] && [ "$ARCH" = amd64 ]; then
            mb="https://github.com/jedisct1/minisign/releases/download/0.11/minisign-0.11-linux.tar.gz"
            if $CURL -o "$TMP/minisign.tgz" "$mb" 2>/dev/null \
               && tar -xzf "$TMP/minisign.tgz" -C "$TMP" 2>/dev/null; then
                ms="$(find "$TMP" -type f -name minisign -perm -u+x 2>/dev/null | head -n1)"
                [ -n "$ms" ] && { chmod +x "$ms"; MINISIGN="$ms"; }
            fi
        fi
    fi
    [ -n "$MINISIGN" ] || fail "minisign is required and could not be installed automatically — install it (\`brew install minisign\` / \`apt-get install minisign\`) and retry; verification will NOT be skipped"
fi

# ---- VERIFY (the trust gate) --------------------------------------------
info "verifying signature"
# 1) signature over the sums file, using the baked pubkey (inline, no key fetch)
"$MINISIGN" -V -P "$PUBKEY" -m "$TMP/SHA256SUMS.txt" -x "$TMP/SHA256SUMS.txt.minisig" >/dev/null \
    || fail "signature verification failed — aborting (refusing to install unverified bytes)"
ok "minisign signature valid"

info "verifying checksum"
# 2) the zip's checksum against the now-trusted sums file
grep -qF "$ZIP" "$TMP/SHA256SUMS.txt" \
    || fail "no checksum entry for $ZIP — release incomplete or tampered; aborting"
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
unzip -q -o "$TMP/$ZIP" -d "$TMP/x" || fail "zip extraction failed — corrupt download?"
[ -f "$TMP/x/install.sh" ] || fail "release zip missing inner install.sh — aborting"

ok "verified — running inner installer"
PREFIX="$PREFIX" BURROWEE_UNINSTALL="${BURROWEE_UNINSTALL:-}" sh "$TMP/x/install.sh"
