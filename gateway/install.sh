#!/bin/sh
# Burrowee outer bootstrap — THE TRUST ANCHOR (POSIX sh, macOS + Linux).
#
#   curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/gateway/install.sh | sh
#
# This is the stable, curl'd-alone entry point for the `gateway` component
# (which bundles the `burrowee` dispatcher). It NEVER runs an unverified byte:
# it downloads the release zip + SHA256SUMS.txt + its minisig, verifies the
# minisign signature with a baked-in PUBLIC key, verifies the zip's sha256
# against the now-trusted sums file, and ONLY THEN unzips and execs the inner
# per-release install.sh. Any failure aborts before anything is installed.
#
# DO NOT EDIT generated copies (gateway/install.sh) by hand — they are produced
# from tools/bootstrap.template.sh by tools/gen-bootstraps.sh.
#
# Env vars:
#   BURROWEE_<COMP>_VERSION      pin a release tag (e.g. gateway/v0.1.0.…); default: latest
#                                (<COMP> = the component name upper-cased, e.g. BURROWEE_CLI_VERSION)
#   PREFIX                       install root (default $HOME/.local; bins at PREFIX/bin)
#   BURROWEE_UNINSTALL=1         pass through to the inner installer to remove bins
#   BURROWEE_RELEASE_REPO        GitHub repo serving releases (default burrowee-git/release)
#   BURROWEE_SKIP_PREFLIGHT=1    skip the OS-dependency preflight (manage deps yourself)
#   BURROWEE_SKIP_NGINX=1        (edge) skip nginx + stream module in the preflight
#   BURROWEE_NO_PATH_EDIT=1      do not persist PREFIX/bin to your shell rc
#   BURROWEE_CHANNEL_BASE        base URL for the static channel (preflight.sh lives here)
#   BURROWEE_DL_BASE             (test hook) download assets from this base instead of GitHub
#   CONSOLE_URL                  Burrowee console base URL; used by the R2 fallback when
#                                GitHub is unreachable (default https://console.burrowee.com)
#   BURROWEE_GH_PROXY            Space-separated list of GitHub HTTP mirrors, tried in order
#                                ONLY when github.com / api.github.com are unreachable
#                                (default: gh-proxy.com gh-proxy.org cdn.gh-proxy.org
#                                v6.gh-proxy.org; set empty to disable). minisign + sha256
#                                verified, so an untrusted mirror cannot tamper undetected.

set -eu

# ---- knobs --------------------------------------------------------------
COMP="gateway"
PUBKEY="RWT/O8xU4IbIBI1rg1T9ddsPLqdhI7wOYaVPDt/9ctT2TkNI2H2yLXFk"
PREFLIGHT_SHA256="4b8eb0778dc7ada812e3e787355b3455f29b74044b22931d89be1591181e5aaf"
REPO="${BURROWEE_RELEASE_REPO:-burrowee-git/release}"
PREFIX="${PREFIX:-$HOME/.local}"
DL_BASE="${BURROWEE_DL_BASE:-}"           # test hook (undocumented to users)
# Static channel base (where preflight.sh lives — a sibling static file, NOT a
# GitHub release asset). $COMP is a baked literal, safe to interpolate.
CHANNEL_BASE="${BURROWEE_CHANNEL_BASE:-https://release.burrowee.com/$COMP}"
# Console base for R2 fallback (version catalog + presigned asset URLs via
# `burrowee download-url`). Only used when GitHub is unreachable AND the host
# has an authorized `burrowee` with a device grant.
CONSOLE_URL="${CONSOLE_URL:-https://console.burrowee.com}"
# GitHub HTTP mirrors, tried in order ONLY as a fallback when github.com /
# api.github.com are unreachable (e.g. networks that block or throttle GitHub).
# Each is tried as <mirror>/<original-https-github-url> until one succeeds; the
# downloaded bytes are still minisign- + sha256-verified below, so an untrusted
# mirror cannot inject tampered bytes undetected. Space-separated list.
# ${VAR-default} (not :-) lets `BURROWEE_GH_PROXY=` explicitly disable the
# mirrors while an unset value gets the default. Never used when DL_BASE is set.
GH_PROXIES="${BURROWEE_GH_PROXY-https://gh-proxy.com https://gh-proxy.org https://cdn.gh-proxy.org https://v6.gh-proxy.org}"

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

# Extract the highest "<comp>/v<semver>" tag from a GitHub /releases JSON body
# read on stdin. The /releases order is by tag-commit date, NOT publish order,
# so it is unreliable for "latest" — pick the highest tag via version sort.
# Match only the real "tag_name" FIELD (line-anchored) so release-notes/body
# text that merely contains the literal `"tag_name"` can't spoof the tag.
# Prefer jq (structural); fall back to grep/sed. Used for both the direct
# api.github.com fetch and the GH_PROXY mirror retry.
latest_tag() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.[].tag_name // empty' 2>/dev/null
    else
        grep -E '^[[:space:]]*"tag_name"[[:space:]]*:' \
            | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
    fi | grep -E "^${COMP}/v" | sort -V | tail -n1
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
    # shellcheck disable=SC2086  # $CURL is an intentional space-split command string (flags + binary); POSIX sh has no arrays.
    body="$($CURL "$api" 2>/dev/null)" || true
    TAG="$(printf '%s' "$body" | latest_tag)" || true
    # GitHub API unreachable/empty — retry through each mirror in turn BEFORE the
    # console catalog (mirrors need no authorized burrowee, so they serve fresh
    # hosts). Skipped under the DL_BASE test hook and when mirrors are disabled.
    if [ -z "$TAG" ] && [ -z "$DL_BASE" ] && [ -n "$GH_PROXIES" ]; then
        for _proxy in $GH_PROXIES; do
            info "GitHub API unreachable — retrying via mirror $_proxy"
            # shellcheck disable=SC2086  # intentional word-split of $CURL flags
            body="$($CURL "$_proxy/$api" 2>/dev/null)" || true
            TAG="$(printf '%s' "$body" | latest_tag)" || true
            if [ -n "$TAG" ]; then info "mirror resolved: $TAG"; break; fi
        done
    fi
    if [ -z "$TAG" ]; then
        # GitHub unreachable or no releases published. Try the console catalog
        # (public, no auth): GET ${CONSOLE_URL}/api/v1/releases/gateway/current.
        # This is the R2 fallback path — assets are served via `burrowee download-url`
        # (see the dl() function below), which requires a device grant.
        info "GitHub unreachable — trying console catalog for latest gateway version"
        catalog_url="${CONSOLE_URL}/api/v1/releases/gateway/current"
        # Use plain curl (no TLS-only flags) when DL_BASE is set for tests, else
        # standard hardened curl.
        # shellcheck disable=SC2086  # intentional word-split of $CURL flags
        catalog_body="$($CURL "$catalog_url" 2>/dev/null)" || true
        TAG="$(printf '%s' "$catalog_body" \
            | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            | head -n1)" || true
        [ -n "$TAG" ] \
            || fail "GitHub and the console catalog are both unreachable — cannot resolve the latest gateway version; retry when either is available"
        info "console catalog: $TAG"
    fi
    info "latest: $TAG"
fi

# ---- download -----------------------------------------------------------
if [ -n "$DL_BASE" ]; then
    BASE="$DL_BASE"
else
    BASE="https://github.com/${REPO}/releases/download/${TAG}"
fi
ZIP="burrowee-${COMP}-${OS}-${ARCH}.zip"
# gh-proxy mirrors route a release download by treating the release TAG as a
# SINGLE path segment. Our tags contain a slash (<comp>/v…), so a LITERAL slash
# splits the tag across two path segments and some mirror edges then fail to
# serve the asset (or return wrong bytes that later fail verification). Build a
# mirror-only base with the tag's slash percent-encoded (%2F) so the tag stays
# one segment. Direct GitHub ($BASE) keeps the literal slash (it 404s on %2F).
MIRROR_BASE="https://github.com/${REPO}/releases/download/$(printf '%s' "${TAG}" | sed 's#/#%2F#g')"

dl() {
    # dl <remote-name> <local-name>  (local goes under $TMP)
    #
    # Primary: download from $BASE (GitHub release or $BURROWEE_DL_BASE test hook).
    # Mirror fallback: if the primary fails, retry the SAME GitHub URL through each
    # GH_PROXIES HTTP mirror in turn (no auth, helps GitHub-blocked networks).
    # R2 fallback (grant gate): if all fail AND `burrowee download-url` is
    # available with a device grant, resolve a presigned URL and download from it.
    # Verification (minisign + sha256) is unchanged regardless of download source,
    # so neither the mirror nor R2 can inject tampered bytes undetected.
    #
    # Only the grant-gated R2 fallback relies on `burrowee` being on PATH. A plain
    # `curl install.sh | sh` with GitHub down and no `burrowee` fails with a clear
    # message — the fallback is for hosts that have already installed burrowee.
    _asset="$1"
    _local="$2"
    # shellcheck disable=SC2086  # $CURL is an intentional space-split command string (flags + binary); POSIX sh has no arrays.
    if $CURL -o "$TMP/$_local" "$BASE/$_asset" 2>/dev/null; then
        return 0
    fi
    # Mirror fallback: route the %2F-encoded GitHub URL (MIRROR_BASE) through each
    # mirror in turn. Only for the real GitHub BASE (skip under the DL_BASE test
    # hook) and when enabled.
    if [ -z "$DL_BASE" ] && [ -n "$GH_PROXIES" ]; then
        for _proxy in $GH_PROXIES; do
            info "primary download failed for $_asset; retrying via mirror $_proxy"
            # shellcheck disable=SC2086  # intentional word-split of $CURL flags
            if $CURL -o "$TMP/$_local" "$_proxy/$MIRROR_BASE/$_asset" 2>/dev/null; then
                ok "downloaded $_asset via mirror $_proxy"
                return 0
            fi
        done
    fi
    # Primary + mirrors failed. Attempt R2 fallback only when `burrowee` is on PATH.
    if command -v burrowee >/dev/null 2>&1; then
        info "primary download failed for $_asset; trying R2 fallback via burrowee"
        _r2url="$(burrowee download-url gateway "$TAG" "$_asset" 2>/dev/null)" || true
        if [ -n "$_r2url" ]; then
            # Scheme guard: the resolved URL MUST be https:// in production, or
            # https:// / http:// in test mode (BURROWEE_DL_BASE set). This prevents
            # a compromised `burrowee` from redirecting to file://, ftp://, or
            # other unsafe schemes. Fail the fallback (not the whole install) if
            # the URL doesn't pass this check — user will see the no-burrowee error path.
            _valid_scheme=0
            case "$_r2url" in
                https://*)
                    _valid_scheme=1
                    ;;
                http://*)
                    # Allow http:// only in test mode (when DL_BASE is set).
                    if [ -n "$DL_BASE" ]; then
                        _valid_scheme=1
                    fi
                    ;;
            esac
            if [ "$_valid_scheme" -eq 1 ]; then
                # shellcheck disable=SC2086  # intentional word-split of $CURL flags
                $CURL -o "$TMP/$_local" "$_r2url" 2>/dev/null \
                    || fail "R2 fallback download failed for $_asset — check device grant and retry"
                ok "downloaded $_asset via R2 fallback"
                return 0
            fi
            # URL scheme invalid — treat as a fallback failure so the caller
            # sees the standard "no authorized burrowee" error.
        fi
        fail "burrowee download-url returned no URL for $_asset — device grant may be expired; run 'burrowee login' to renew, or retry when GitHub is reachable"
    fi
    fail "download failed: $_asset (from $BASE; mirrors: $GH_PROXIES) — GitHub and all mirrors are unreachable and there is no authorized burrowee on PATH — install burrowee + run 'burrowee login' to enable the backup channel, or retry when GitHub is reachable"
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
# fresh shell finds `burrowee` (the live-VPS `command not found`). bash reads
# ~/.bashrc for INTERACTIVE shells, but a LOGIN shell (ssh) reads the first of
# ~/.bash_profile / ~/.bash_login / ~/.profile and does NOT auto-source ~/.bashrc
# — so write to both the interactive rc and the login file, else PATH is missing
# over ssh. An unset/unknown $SHELL defaults to the bash files. Fault-tolerant:
# an unwritable rc must never abort the script (the bins are already installed).
if [ -z "${BURROWEE_UNINSTALL:-}" ] && [ -z "${BURROWEE_NO_PATH_EDIT:-}" ]; then
    BIN_DIR="$PREFIX/bin"
    case ":$PATH:" in
        *":$BIN_DIR:"*) : ;;   # already on PATH this shell
        *)
            # rc set: interactive rc + the login file the shell actually sources.
            case "$(basename "${SHELL:-bash}")" in
                zsh)
                    rc_files="$HOME/.zshrc"
                    [ -f "$HOME/.zprofile" ] && rc_files="$rc_files $HOME/.zprofile"
                    ;;
                *)  # bash (and any unrecognized shell defaults to bash rc files)
                    rc_files="$HOME/.bashrc"
                    if   [ -f "$HOME/.bash_profile" ]; then rc_files="$rc_files $HOME/.bash_profile"
                    elif [ -f "$HOME/.bash_login" ];   then rc_files="$rc_files $HOME/.bash_login"
                    else rc_files="$rc_files $HOME/.profile"; fi
                    ;;
            esac
            for rc in $rc_files; do
                if [ -f "$rc" ] && grep -q 'burrowee PATH' "$rc" 2>/dev/null; then
                    continue   # marker already present in this file
                fi
                {
                    printf '\n# >>> burrowee PATH >>>\n'
                    printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
                    printf '# <<< burrowee PATH <<<\n'
                } >> "$rc" 2>/dev/null && info "added $BIN_DIR to PATH in $rc"
            done
            info "run: export PATH=\"$BIN_DIR:\$PATH\"   (or open a new shell) to use burrowee now"
            ;;
    esac
fi
