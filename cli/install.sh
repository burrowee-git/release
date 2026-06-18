#!/bin/sh
# Burrowee outer bootstrap — THE TRUST ANCHOR (POSIX sh, macOS + Linux).
#
#   curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/cli/install.sh | sh
#
# This is the stable, curl'd-alone entry point for the `cli` component
# (which bundles the `burrowee` dispatcher). It NEVER runs an unverified byte:
# it downloads the release zip + SHA256SUMS.txt + its minisig, verifies the
# minisign signature with a baked-in PUBLIC key, verifies the zip's sha256
# against the now-trusted sums file, and ONLY THEN unzips and execs the inner
# per-release install.sh. Any failure aborts before anything is installed.
#
# DO NOT EDIT generated copies (cli/install.sh) by hand — they are produced
# from tools/bootstrap.template.sh by tools/gen-bootstraps.sh.
#
# Env vars:
#   BURROWEE_<COMP>_VERSION      pin a release tag (e.g. cli/v0.1.0.…); default: latest
#                                (<COMP> = the component name upper-cased, e.g. BURROWEE_CLI_VERSION)
#   PREFIX                       install root (default $HOME/.local; bins at PREFIX/bin)
#   BURROWEE_UNINSTALL=1         pass through to the inner installer to remove bins
#   BURROWEE_RELEASE_REPO        GitHub repo serving releases (default burrowee-git/release)
#   BURROWEE_SKIP_PREFLIGHT=1    skip the OS-dependency preflight (manage deps yourself)
#   BURROWEE_SKIP_NGINX=1        (edge) skip nginx + stream module in the preflight
#   BURROWEE_NO_PATH_EDIT=1      do not persist PREFIX/bin to your shell rc
#   BURROWEE_CHANNEL_BASE        base URL for the static channel (preflight.sh lives here)
#   BURROWEE_DL_BASE             (test hook) download assets from this base instead of GitHub

set -eu

# ---- knobs --------------------------------------------------------------
COMP="cli"
PUBKEY="RWT/O8xU4IbIBI1rg1T9ddsPLqdhI7wOYaVPDt/9ctT2TkNI2H2yLXFk"
PREFLIGHT_SHA256="ebaef1bddbf43566efbc9a4e664cc72bd2aebf7312890e08ce04e7263b1085af"
REPO="${BURROWEE_RELEASE_REPO:-burrowee-git/release}"
PREFIX="${PREFIX:-$HOME/.local}"
DL_BASE="${BURROWEE_DL_BASE:-}"           # test hook (undocumented to users)
# Static channel base (where preflight.sh lives — a sibling static file, NOT a
# GitHub release asset). $COMP is a baked literal, safe to interpolate.
CHANNEL_BASE="${BURROWEE_CHANNEL_BASE:-https://release.burrowee.com/$COMP}"

# Production downloads are pinned to HTTPS/TLS1.2 (--proto =https). The
# BURROWEE_DL_BASE test hook points at a local plain-HTTP server, so when it is
# set we drop the TLS-only flags (they'd reject http://); the version-pin guard
# below keeps even that path scheme-locked to the test base.
if [ -n "$DL_BASE" ]; then
    CURL="curl -fsSL --connect-timeout 15 --max-time 300"
else
    CURL="curl -fsSL --proto =https --tlsv1.2 --connect-timeout 15 --max-time 300"
fi

# ---- helpers ------------------------------------------------------------
fail() { printf '\n  ✗ %s\n\n' "$*" >&2; exit 1; }
info() { printf '  → %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else return 1; fi
}

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

# ---- preflight (install OS deps before the trust gate) ------------------
# preflight.sh installs minisign/unzip/curl (the trust gate's deps) + nginx for
# edge, with root, from the OS package manager. It runs BEFORE `require minisign`.
# It is fetched from the static CHANNEL_BASE (a sibling static file, NOT a GitHub
# release asset), and verified against a baked sha256 — there is no minisign yet,
# so the sha256 pin is the integrity anchor (preflight only invokes the OS package
# manager, whose repos are themselves signed). Skipped on uninstall or via env.
if [ -z "${BURROWEE_UNINSTALL:-}" ] && [ -z "${BURROWEE_SKIP_PREFLIGHT:-}" ]; then
    info "preflight: ensuring OS dependencies"
    PF_BASE="${DL_BASE:-$CHANNEL_BASE}"
    # shellcheck disable=SC2086
    $CURL -o "$TMP/preflight.sh" "$PF_BASE/preflight.sh" \
        || fail "could not download preflight.sh from $PF_BASE — set BURROWEE_SKIP_PREFLIGHT=1 to install deps yourself"
    case "$PREFLIGHT_SHA256" in
        ""|*PLACEHOLDER*|*TEMP*) fail "preflight checksum not baked — regenerate with tools/gen-bootstraps.sh" ;;
    esac
    pf_got="$(sha256_of "$TMP/preflight.sh")" || fail "cannot checksum preflight (need shasum or sha256sum)"
    [ "$pf_got" = "$PREFLIGHT_SHA256" ] \
        || fail "preflight.sh checksum mismatch (expected $PREFLIGHT_SHA256, got $pf_got) — refusing to run a tampered preflight"
    ok "preflight verified"
    sh "$TMP/preflight.sh" || info "preflight could not complete fully — continuing; the trust gate will verify required tools"
fi

# ---- version resolution -------------------------------------------------
# Read the per-component pin env var by name (no eval). $COMP is a baked
# literal, so a direct case over the three known components is exhaustive.
case "$COMP" in
    cli)     PIN="${BURROWEE_CLI_VERSION:-}" ;;
    gateway) PIN="${BURROWEE_GATEWAY_VERSION:-}" ;;
    edge)    PIN="${BURROWEE_EDGE_VERSION:-}" ;;
    *)       fail "unknown component '$COMP' — cannot resolve its version pin" ;;
esac
if [ -n "$PIN" ]; then
    TAG="$PIN"
    info "using pinned version: $TAG"
else
    info "resolving latest ${COMP} release"
    api="https://api.github.com/repos/${REPO}/releases?per_page=100"
    # The GitHub /releases order is by tag-commit date, NOT publish order, so it is
    # unreliable for "latest" — pick the highest "<comp>/v<semver>" via version sort.
    # Extract only the real "tag_name" FIELD — anchored to the start of its line —
    # so release-notes/body text that merely contains the literal `"tag_name"`
    # can't spoof the tag. Prefer jq (structural) and fall back to grep/sed.
    # shellcheck disable=SC2086  # $CURL is an intentional space-split command string (flags + binary); POSIX sh has no arrays.
    body="$($CURL "$api" 2>/dev/null)" || true
    if command -v jq >/dev/null 2>&1; then
        TAG="$(printf '%s' "$body" \
            | jq -r '.[].tag_name // empty' \
            | grep -E "^${COMP}/v" \
            | sort -V \
            | tail -n1)" || true
    else
        TAG="$(printf '%s' "$body" \
            | grep -E '^[[:space:]]*"tag_name"[[:space:]]*:' \
            | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
            | grep -E "^${COMP}/v" \
            | sort -V \
            | tail -n1)" || true
    fi
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
    # shellcheck disable=SC2086  # $CURL is an intentional space-split command string (flags + binary); POSIX sh has no arrays.
    $CURL -o "$TMP/$2" "$BASE/$1" \
        || fail "download failed: $1 (from $BASE) — refusing to install unverified bytes"
}
info "downloading $ZIP"
dl "$ZIP" "$ZIP"
info "downloading SHA256SUMS.txt + signature"
dl "SHA256SUMS.txt"         "SHA256SUMS.txt"
dl "SHA256SUMS.txt.minisig" "SHA256SUMS.txt.minisig"

# ---- require minisign ---------------------------------------------------
# minisign is the trust root: it must already be on PATH from a trusted source
# (your package manager). We never auto-fetch the verifier — a binary pulled
# over the network and run unverified would itself become an unverified trust
# root, defeating the whole signature chain. Verification is mandatory and is
# only ever performed by a minisign the operator already trusts.
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
# Run with cwd = the unzipped dir: the inner installer resolves the binaries
# relative to its own location (./burrowee, ./burrowee-cli, …).
( cd "$TMP/x" && PREFIX="$PREFIX" BURROWEE_UNINSTALL="${BURROWEE_UNINSTALL:-}" BURROWEE_VERSION="$TAG" sh ./install.sh )

# ---- PATH persistence ---------------------------------------------------
# On a real install, idempotently add PREFIX/bin to the operator's shell rc so a
# fresh shell finds `burrowee` (the live-VPS `command not found`). Fault-tolerant:
# an unwritable rc must never abort the script (the bins are already installed).
if [ -z "${BURROWEE_UNINSTALL:-}" ] && [ -z "${BURROWEE_NO_PATH_EDIT:-}" ]; then
    BIN_DIR="$PREFIX/bin"
    case ":$PATH:" in
        *":$BIN_DIR:"*) : ;;   # already on PATH this shell
        *)
            # choose rc by login shell
            case "$(basename "${SHELL:-}")" in
                zsh)  rc="$HOME/.zshrc" ;;
                bash) rc="$HOME/.bashrc" ;;
                *)    rc="$HOME/.profile" ;;
            esac
            if [ -f "$rc" ] && grep -q 'burrowee PATH' "$rc" 2>/dev/null; then
                : # marker already present
            else
                {
                    printf '\n# >>> burrowee PATH >>>\n'
                    printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
                    printf '# <<< burrowee PATH <<<\n'
                } >> "$rc" 2>/dev/null && info "added $BIN_DIR to PATH in $rc"
            fi
            info "run: export PATH=\"$BIN_DIR:\$PATH\"   (or open a new shell) to use burrowee now"
            ;;
    esac
fi
