#!/usr/bin/env bash
# apple_sign.sh — Developer-ID signing preconditions, sourced by tools/release.sh.
#
# These two checks decide whether a --public cut is Developer-ID signed or
# quietly ad-hoc signed, so they live here as functions rather than inline in the
# orchestrator: tools/apple_sign.test.sh exercises them directly, with no part of
# the release path running. Same split as tools/vulncheck.sh.

# load_apple_account <repo_root>
# Resolves the Apple account plugin and exports APPLE_ACCOUNT, APPLE_HOME and
# APPLE_ACCOUNT_DIR for modernech-sign and for `rkit build` (which reads them
# rather than re-deriving them — this file is the single owner of the machine
# layout; the Go side requires APPLE_HOME and bakes no default, the repo being
# public). <repo_root>/config/apple-account holds one line: the folder name
# under $APPLE_HOME.
#
# Called only when Apple signing was requested, so every unresolved state
# returns 1: continuing produces an AD-HOC signed cut while the operator
# believes it is Developer-ID signed and notarized.
load_apple_account() {
    local repo_root="$1"
    local conf="${repo_root}/config/apple-account"
    [ -f "$conf" ] || conf="${repo_root}/config/apple.account"
    local name=""
    if [ -f "$conf" ]; then
        name="$(sed -n '/^[[:space:]]*#/d;/^[[:space:]]*$/d;p;q' "$conf" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    fi
    # An already-exported APPLE_ACCOUNT wins — an operator cutting under a second
    # account exports it, and `rkit build` has always honoured that. Overriding it
    # here made the same export respected by one entry point and silently ignored
    # by the other.
    export APPLE_ACCOUNT="${APPLE_ACCOUNT:-$name}"
    if [ -z "${APPLE_ACCOUNT}" ]; then
        echo "✗ Apple signing requested but no Apple account resolved" >&2
        echo "  create ${repo_root}/config/apple-account with the account plugin folder name," >&2
        echo "  or export APPLE_ACCOUNT / APPLE_ACCOUNT_DIR" >&2
        return 1
    fi
    export APPLE_HOME="${APPLE_HOME:-$HOME/Workstation/Apple}"
    export APPLE_ACCOUNT_DIR="${APPLE_ACCOUNT_DIR:-$APPLE_HOME/$APPLE_ACCOUNT}"
    if [ ! -d "$APPLE_ACCOUNT_DIR" ]; then
        echo "✗ Apple account folder missing: $APPLE_ACCOUNT_DIR" >&2
        echo "  Apple signing was requested (--apple/--public) but the account plugin is not there;" >&2
        echo "  refusing to cut an ad-hoc signed release that would look Developer-ID signed." >&2
        return 1
    fi
    echo "→ Apple account: $APPLE_ACCOUNT ($APPLE_ACCOUNT_DIR)" >&2
}

# resolve_sign_identity <sign_bin>
# Prints the Developer-ID identity <sign_bin> reports, or returns 1 with a
# report when it produces nothing.
#
# The emptiness check is the whole point. Inlined as
# `grep -q "$("${SIGN_BIN}" id)"` the gate degraded to `grep -q ""` whenever
# `modernech-sign id` failed or printed nothing — the EXPECTED outcome when
# APPLE_ACCOUNT_DIR points somewhere that does not exist — and an empty pattern
# matches the first line of any output, so the gate passed VACUOUSLY with no
# reachable identity at all. The surrounding `if ! … && ! …` also suppresses
# set -e/pipefail, so a failing `${SIGN_BIN} id` could not abort on its own.
resolve_sign_identity() {
    local sign_bin="$1" id
    id="$("${sign_bin}" id 2>/dev/null || true)"
    if [ -z "${id}" ]; then
        echo "✗ --apple set but '${sign_bin} id' produced no identity" >&2
        echo "  usually APPLE_ACCOUNT_DIR points at a missing account plugin: ${APPLE_ACCOUNT_DIR:-<unset>}" >&2
        echo "  refusing to continue: the Developer ID gate cannot be checked without an identity." >&2
        return 1
    fi
    printf '%s' "${id}"
}

# sign_identity_reachable <identity>
# True when <identity> could actually be used to sign: either rcodesign is on
# PATH (modernech-sign's disk-key backend, where the identity never enters a
# keychain) or the identity is in this session's codesigning keychain.
#
# -F: the identity is a literal string ("Developer ID Application: X (TEAMID)"),
# not a regex — its parentheses must not be interpreted. --: it must never be
# read as an option. An empty argument is rejected outright rather than matching
# everything.
sign_identity_reachable() {
    local id="$1"
    [ -n "${id}" ] || return 1
    command -v rcodesign >/dev/null 2>&1 && return 0
    security find-identity -v -p codesigning 2>/dev/null | grep -qF -- "${id}"
}
