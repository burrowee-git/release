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
#   7. Unzip + elevate (relay is root-only) + run inner install.sh.
#   8. Store operator key at ~/.burrowee/relay/release_dl.key (0600) for update.
#
# DO NOT EDIT generated copies (relay/install.sh) by hand — they are produced
# from tools/relay-bootstrap.template.sh by tools/gen-bootstraps.sh.
#
# Env vars:
#   BURROWEE_RELAY_DL_KEY        path to the operator ed25519 PEM private key
#                                (alternative to --key <pem>)
#   BURROWEE_RELAY_VERSION       pin a release stamp (e.g. 20260617120000); default: latest
#   BURROWEE_UNINSTALL=1         pass through to the inner installer to remove bins
#   BURROWEE_DL_BASE             (test hook) download from this base instead of release.burrowee.com
#   OPENSSL                      override the openssl binary (default: openssl)
#   (elevation)                  relay is root-only: the bootstrap runs the VERIFIED
#                                inner installer under sudo and says so. Resolution,
#                                download and signature checks stay at the invoking
#                                user. No tty + no cached creds, or no sudo at all,
#                                is a refusal before anything is placed.
#
# NO PREFIX. As of relay 0.2.2 the inner installer is root-only with ONE
# destination — /usr/local/burrowee/bin as of 0.3, /usr/local/bin through 0.2 — and it REFUSES a PREFIX that would MISDIRECT the
# install rather than honouring or silently overriding it. One that resolves to
# that same destination misdirects nothing: it is honoured with a line saying
# so, then cleared. This bootstrap therefore never manufactures one — the old
# `PREFIX=$HOME/.local` default sent a root install to /root/.local/bin while
# the fleet's units named the system exec root, which is exactly the split the refusal
# makes loud. An operator-exported PREFIX still reaches the inner installer
# through the environment, so the refusal is reachable, not silent.

set -eu

# ---- knobs --------------------------------------------------------------
COMP="@COMP@"
PUBKEY="@PUBKEY@"
BASE="${BURROWEE_DL_BASE:-https://release.burrowee.com}"
OPENSSL="${OPENSSL:-openssl}"
# MODE and CHANNEL_BASE exist only so the elevation block's refusal message
# below -- pinned byte-identical with tools/bootstrap.template.sh's copy --
# can reference $CHANNEL_BASE/$MODE.sh without an unbound-variable error under
# `set -eu`. relay has no install/upgrade split (see the header): it always
# installs, and its channel is the gated one this same host serves.
MODE="install"
CHANNEL_BASE="$BASE/$COMP"

# Production downloads are pinned to HTTPS/TLS1.2 (--proto =https). The
# BURROWEE_DL_BASE test hook points at a local plain-HTTP server, so when it is
# set we drop the TLS-only flags (they'd reject http://); signed requests are
# still verified against the baked pubkey regardless.
CURL_BUDGET="--connect-timeout 15 --max-time 300"
if [ -n "${BURROWEE_DL_BASE:-}" ]; then
    CURL_TLS=""
else
    CURL_TLS="--proto =https --tlsv1.2"
fi
CURL="curl -fsSL $CURL_TLS $CURL_BUDGET"

# CURL_DL — the gated relay artifact, fetched with a progress meter when a
# person is watching. Same rationale and same constraints as the public
# bootstrap: the meter goes to STDERR so stdout and the data path are untouched,
# and a non-interactive install stays exactly as quiet as it is today.
if [ -t 2 ] && [ -z "${BURROWEE_NO_PROGRESS:-}" ]; then
    CURL_DL="curl -fSL --progress-bar $CURL_TLS $CURL_BUDGET"
else
    CURL_DL="$CURL"
fi

# ---- helpers ------------------------------------------------------------
@INCLUDE:helpers@

# ---- elevation ----------------------------------------------------------
# THE POLICY: a root-only surface never dead-ends. gateway, edge and relay
# install to /usr/local/burrowee/bin and manage a system service; they cannot install any
# other way. So the bootstrap elevates rather than printing a one-liner for the
# operator to retype.
#
# WHERE, and why it is here and not at the top: everything above this point --
# resolving the tag, downloading, minisign, sha256, the preflight -- runs at the
# OPERATOR's uid. Root executes only bytes already proven to be the signed
# release. Elevating at the top would run the whole network-facing chain as root
# for no gain, and would put the preflight's brew path (Homebrew refuses to run
# as root) on the wrong side of the boundary. Do not reorder this.
needs_root_comp() {
    # relay is root-only as of 0.2.2 -- one destination, /usr/local/burrowee/bin (0.3; /usr/local/bin through 0.2).
    return 0
}

# ELEVATE_HINT -- the exact re-run command the pinned refusal below shows when
# this run has no tty and no cached sudo credentials. Lives HERE, beside
# needs_root_comp(), for the same reason it differs there: unlike
# gateway/edge, relay is gated by an operator ed25519 key (--key <pem> or
# BURROWEE_RELAY_DL_KEY) that a plain `curl … | sudo sh` cannot carry across
# the sudo boundary -- sudo has nothing to forward it as (the pipe supplies no
# argv for `sh -s --`), sudo scrubs BURROWEE_RELAY_DL_KEY from the child's env
# by default, and HOME becomes /root so a key stored at the invoking user's
# own ~/.burrowee/relay/release_dl.key is not found either. The one form that
# genuinely works is to become root FIRST (so resolve_elevate sees uid 0 and
# never calls sudo at all) and hand the key straight to the script as an
# argument, the same `sh -s -- --key <pem>` shape documented at the top of
# this file.
ELEVATE_HINT="this needs the operator key, and sudo cannot carry it across — become root first (\`sudo -i\`), then:
    curl -fsSL --proto '=https' --tlsv1.2 $CHANNEL_BASE/$MODE.sh | sh -s -- --key <path-to-your-operator-key>"

# ---- BEGIN pinned elevation literals -------------------------------------
# Kept byte-identical between tools/bootstrap.template.sh and
# tools/relay-bootstrap.template.sh — tools/test-elevate.sh assertion (9)
# diffs everything between these two markers. needs_root_comp() above is
# deliberately OUTSIDE the pinned range: it differs by design (the shared
# template switches on $COMP; relay is root-only unconditionally).
# has_tty -- copied VERBATIM from inner/gateway/install.sh, which already solves
# the piped case: under `curl … | sh` stdin IS the script, so `[ -t 0 ]` is
# false, and the /dev/tty probe is the only thing that finds the terminal.
has_tty() {
    [ -t 0 ] && return 0
    ( exec </dev/tty ) 2>/dev/null
}

# resolve_elevate -- prints `sudo`, or nothing. Refuses (exit 1) rather than
# proceeding toward an install that cannot finish.
resolve_elevate() {
    needs_root_comp || return 0
    [ "$(id -u)" != 0 ] || return 0
    if ! command -v sudo >/dev/null 2>&1; then
        fail "$COMP installs to /usr/local/burrowee/bin and manages a system service, so it needs root — and sudo is not installed on this host. Re-run this installer as root."
    fi
    if ! has_tty && ! sudo -n true 2>/dev/null; then
        fail "$COMP needs root to install, and this run has no terminal for a sudo password prompt and no cached sudo credentials. Re-run it from an interactive terminal, pre-authorize with \`sudo -v\`, or run:
    $ELEVATE_HINT"
    fi
    printf 'sudo'
}
ELEVATE="$(resolve_elevate)"
# ---- END pinned elevation literals ---------------------------------------

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
# Darwin is refused HERE, before anything is downloaded. The relay installer has
# no launchd branch — it manages services purely through $SYSTEMCTL — so a macOS
# run used to place four binaries, run the migration ladder, write the version
# marker and self-copy, and only THEN die on "systemctl: command not found",
# leaving a half-installed host. Refusing up front is strictly better than
# aborting mid-install. Revisit when relay actually ships a launchd unit.
case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) fail "burrowee relay has no macOS support: its installer manages services through systemd only (linux arm64 + amd64)" ;;
    *)      fail "unsupported OS: $(uname -s) (burrowee relay ships linux only)" ;;
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

# ---- download (gated) ---------------------------------------------------
@INCLUDE:download-r2-only@

# ---- require minisign ---------------------------------------------------
# minisign is the trust root: it must already be on PATH from a trusted source
# (your package manager). We never auto-fetch the verifier — a binary pulled
# over the network and run unverified would itself become an unverified trust
# root, defeating the whole signature chain. Verification is mandatory.
if command -v minisign >/dev/null 2>&1; then
    MINISIGN=minisign
else
    case "$OS" in
        darwin) hint="install Homebrew if you don't have it, then minisign:
      /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
      brew install minisign" ;;
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
@INCLUDE:sha256@
@INCLUDE:verify-checksum@
ok "checksum verified"

# ---- unzip + exec the verified inner installer --------------------------
command -v unzip >/dev/null 2>&1 \
    || fail "unzip not found — install it (\`brew install unzip\` / \`apt-get install unzip\`) and retry"
unzip -q -o "$TMP/$ZIP" -d "$TMP/x" || fail "zip extraction failed — corrupt download?"
[ -f "$TMP/x/install.sh" ] || fail "release zip missing inner install.sh — aborting"

ok "verified — running inner installer"
# run_inner — exec the verified inner installer with cwd = the unzipped dir, so
# it resolves the binaries relative to its own location. PREFIX is deliberately
# NOT resolved or defaulted here: the 0.2.2 root-only installer has one
# destination (/usr/local/burrowee/bin) and refuses, loudly, any PREFIX that names
# somewhere else; one that resolves to that same destination is honoured as the
# no-op it is. An operator-exported PREFIX must still reach the inner installer
# for that refusal to be reachable rather than silently dropped — and now that
# the install step runs under sudo, plain environment inheritance no longer
# carries it (sudo scrubs the environment), so it is forwarded explicitly as a
# command-prefix assignment on the `env` invocation, the same boundary-crossing
# pattern tools/bootstrap.template.sh uses for its own PREFIX. No PATH
# persistence either: the inner installer owns the PATH question and prints the
# `export PATH=…` line for the operator's own login shell itself, so there is no
# rc file for this script to edit. (tools/bootstrap.template.sh used to edit one
# for cli and agent; that block is deleted — see its own header for why.)
#
# RELAY'S INSTALLER IS NOT IN THIS REPO, and at the time of writing it still
# LINKS burrowee-relay-cli into /usr/local/bin when that directory is
# root-secure — the step every other component has now deleted. rkit resolves
# relay's install.sh from the source tree being built (cmd/rkit/build.go), so
# it is the relay repo's to change and this description is deliberately not a
# claim about behaviour this repo controls. What this repo DOES control bites
# either way: payload.sh's takes_shared_ladder stages the shared ladder for
# relay, so a relay kit already carries the inverted sweep, which removes links
# into $BIN_DIR. Until relay's own installer drops its link step, a relay
# install can make three links and sweep them in the same run. That is tracked
# as a blocker on any relay cut, not as something to patch from here.
run_inner() {
    if [ -n "$ELEVATE" ]; then
        info "$COMP installs to /usr/local/burrowee/bin and manages a system service — elevating with sudo for the install step (the download and its signature check already ran as $(id -un))"
    fi
    if [ -n "${PREFIX:-}" ]; then
        ( cd "$TMP/x" && $ELEVATE env PREFIX="$PREFIX" \
            BURROWEE_UNINSTALL="${BURROWEE_UNINSTALL:-}" sh ./install.sh )
    else
        ( cd "$TMP/x" && $ELEVATE env \
            BURROWEE_UNINSTALL="${BURROWEE_UNINSTALL:-}" sh ./install.sh )
    fi
}
run_inner

# ---- store operator key for relay update --------------------------------
# Store the key at the canonical path so `relay update` can find it without
# requiring --key on every invocation.
KEY_DIR="$HOME/.burrowee/relay"
mkdir -p "$KEY_DIR"
cp "$KEY" "$KEY_DIR/release_dl.key"
chmod 600 "$KEY_DIR/release_dl.key"
ok "stored operator key at $KEY_DIR/release_dl.key (for relay update)"
