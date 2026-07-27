#!/usr/bin/env bash
# apple_sign.sh — Developer-ID signing preconditions, sourced by tools/release.sh.
#
# These two checks decide whether a --public cut is Developer-ID signed or
# quietly ad-hoc signed, so they live here as functions rather than inline in the
# orchestrator: tools/apple_sign.test.sh exercises them directly, with no part of
# the release path running. Same split as tools/vulncheck.sh.

# _first_config_line <file>
# Prints the first non-blank, non-comment line, trimmed. Nothing when the file
# is absent or holds only comments and blanks.
_first_config_line() {
    [ -f "$1" ] || return 0
    sed -n '/^[[:space:]]*#/d;/^[[:space:]]*$/d;p;q' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# _apple_fix_hint <repo_root> <config-file> <env-var> <what it holds>
# Lists every way to supply a missing value, so the operator can get unstuck
# from the error alone without opening the runbook.
_apple_fix_hint() {
    echo "  supply it as one of:" >&2
    echo "    $1/config/$2" >&2
    echo "        one line: $4" >&2
    echo "    \$$3" >&2
    echo "        the same value, from the environment" >&2
    echo "    \$APPLE_ACCOUNT_DIR" >&2
    echo "        the account's folder itself, which settles account and home together" >&2
}

# load_apple_account <repo_root>
# Resolves the Apple account plugin and exports APPLE_ACCOUNT, APPLE_HOME and
# APPLE_ACCOUNT_DIR for modernech-sign.
#
# Both values resolve the same way — an explicit environment variable first,
# then a per-product config file:
#
#   account   APPLE_ACCOUNT → config/apple-account   (the plugin folder name)
#   home      APPLE_HOME    → config/apple-home      (the absolute plugin root)
#
# or APPLE_ACCOUNT_DIR names the account's folder directly and settles both.
#
# `rkit build` carries its OWN copy of this resolution (cmd/rkit/apple_account.go)
# and does not inherit this one: release.sh never invokes rkit — rkit produces,
# release.sh distributes what rkit staged. So the two are independent
# implementations sharing a PRECEDENCE contract, not an environment. That
# contract is now the whole chain: this copy used to default APPLE_HOME to a
# baked $HOME path while the Go copy refused to default at all, so the two
# entry points disagreed about where plugins live. The config file replaces the
# baked default — it is gitignored, so a machine path never enters this PUBLIC
# repo, and $HOME is never consulted (it is unset under launchd, cron, and a
# detached harness session, where the default silently went RELATIVE).
#
# Called only when Apple signing was requested, so every unresolved state
# returns 1: continuing produces an AD-HOC signed cut while the operator
# believes it is Developer-ID signed and notarized.
load_apple_account() {
    local repo_root="$1"

    if [ -n "${APPLE_ACCOUNT_DIR:-}" ]; then
        if [ ! -d "${APPLE_ACCOUNT_DIR}" ]; then
            echo "✗ Apple signing requested (--apple/--public) but APPLE_ACCOUNT_DIR points at" >&2
            echo "  ${APPLE_ACCOUNT_DIR}, which is not a directory" >&2
            echo "  refusing to continue: signing with no account plugin produces an AD-HOC build" >&2
            echo "  that looks Developer-ID signed." >&2
            return 1
        fi
        export APPLE_ACCOUNT_DIR
        echo "→ Apple account dir (from APPLE_ACCOUNT_DIR): ${APPLE_ACCOUNT_DIR}" >&2
        return 0
    fi

    # An already-exported value wins — an operator cutting under a second account,
    # or against a second plugin root, exports it, and `rkit build` has always
    # honoured that. Overriding it here made the same export respected by one
    # entry point and silently ignored by the other.
    local conf="${repo_root}/config/apple-account"
    [ -f "$conf" ] || conf="${repo_root}/config/apple.account"
    export APPLE_ACCOUNT="${APPLE_ACCOUNT:-$(_first_config_line "$conf")}"
    if [ -z "${APPLE_ACCOUNT}" ]; then
        echo "✗ Apple signing requested (--apple/--public) but APPLE_ACCOUNT is unresolved" >&2
        _apple_fix_hint "${repo_root}" "apple-account" "APPLE_ACCOUNT" \
            "the Apple account plugin folder name"
        echo "  refusing to continue: signing with no account plugin produces an AD-HOC build" >&2
        echo "  that looks Developer-ID signed." >&2
        return 1
    fi

    local home_conf="${repo_root}/config/apple-home"
    [ -f "$home_conf" ] || home_conf="${repo_root}/config/apple.home"
    export APPLE_HOME="${APPLE_HOME:-$(_first_config_line "$home_conf")}"
    if [ -z "${APPLE_HOME}" ]; then
        echo "✗ Apple signing requested (--apple/--public) but APPLE_HOME is unresolved" >&2
        _apple_fix_hint "${repo_root}" "apple-home" "APPLE_HOME" \
            "the absolute directory holding one folder per Apple account"
        echo "  refusing to continue: signing with no account plugin produces an AD-HOC build" >&2
        echo "  that looks Developer-ID signed." >&2
        return 1
    fi
    case "${APPLE_HOME}" in
        /*) ;;
        *)
            echo "✗ Apple signing requested (--apple/--public) but APPLE_HOME resolved to" >&2
            echo "  \"${APPLE_HOME}\", which is not an absolute path" >&2
            return 1
            ;;
    esac

    export APPLE_ACCOUNT_DIR="${APPLE_HOME}/${APPLE_ACCOUNT}"
    if [ ! -d "$APPLE_ACCOUNT_DIR" ]; then
        echo "✗ Apple signing requested (--apple/--public) but the account plugin folder points at" >&2
        echo "  ${APPLE_ACCOUNT_DIR}, which is not a directory" >&2
        echo "  refusing to continue: signing with no account plugin produces an AD-HOC build" >&2
        echo "  that looks Developer-ID signed." >&2
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
# Accepting any non-empty string is still too loose: a one-line diagnostic, a
# usage message, or "0 valid identities found" would all be spliced into the
# keychain match as a pattern that matches nothing, turning a misconfiguration
# into the misleading "identity unreachable" error instead of "no identity".
# The shape is not guessed — `modernech-sign id` prints exactly one line:
#
#     Developer ID Application: Modernech LLC (4J6JX598BJ)
#
# which is Apple's own canonical certificate common name, the same string
# `security find-identity` quotes. So require exactly that: one line, the
# "Developer ID Application: " prefix (this gate exists only for Developer-ID
# signing — --apple means that tier and no other), a non-empty organisation, and
# a trailing 10-character Apple Team ID in parentheses. If modernech-sign is ever
# taught another signing tier, this is an intentional edit, not a silent pass.
apple_identity_pattern='^Developer ID Application: .+ \([A-Z0-9]{10}\)$'

resolve_sign_identity() {
    local sign_bin="$1" id
    id="$("${sign_bin}" id 2>/dev/null || true)"
    # Trim surrounding whitespace: " " is non-empty but is not an identity.
    id="$(printf '%s' "${id}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -z "${id}" ]; then
        echo "✗ --apple set but '${sign_bin} id' produced no identity" >&2
        echo "  usually APPLE_ACCOUNT_DIR points at a missing account plugin: ${APPLE_ACCOUNT_DIR:-<unset>}" >&2
        echo "  refusing to continue: the Developer ID gate cannot be checked without an identity." >&2
        return 1
    fi
    if [ "$(printf '%s\n' "${id}" | wc -l | tr -d ' ')" != 1 ]; then
        echo "✗ --apple set but '${sign_bin} id' printed more than one line:" >&2
        printf '%s\n' "${id}" | sed 's/^/    /' >&2
        echo "  expected a single Developer ID identity; refusing to continue." >&2
        return 1
    fi
    if ! [[ ${id} =~ ${apple_identity_pattern} ]]; then
        echo "✗ --apple set but '${sign_bin} id' did not print a Developer ID identity:" >&2
        echo "    ${id}" >&2
        echo "  expected 'Developer ID Application: <Org> (<10-char Team ID>)'." >&2
        echo "  refusing to continue: this string would be matched against the keychain as-is." >&2
        return 1
    fi
    printf '%s' "${id}"
}

# sign_identity_reachable <identity>
# True when <identity> could actually be used to sign: either rcodesign is on
# PATH (modernech-sign's disk-key backend, where the identity never enters a
# keychain) or the identity appears in this session's codesigning keychain.
#
# The keychain listing is CAPTURED and matched with `case`, not piped into grep.
# Two reasons:
#
#   1. `security … | grep -q` is a SIGPIPE hazard. grep -q exits the instant it
#      matches, so `security` can be killed mid-write and exit 141 — and under
#      release.sh's `set -euo pipefail` the pipeline then reports 141 even though
#      the identity WAS found, failing a legitimate cut at random. Observed as a
#      flaky 141 in this function's own unit test.
#   2. `case` with a QUOTED variable matches literally, so the identity's
#      parentheses cannot be read as a pattern — the same guarantee `grep -F`
#      gave, without depending on grep's flags or on `--` option handling.
#
# An empty identity is rejected outright rather than matching everything.
sign_identity_reachable() {
    local id="$1" listing
    [ -n "${id}" ] || return 1
    command -v rcodesign >/dev/null 2>&1 && return 0
    listing="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    case "${listing}" in
        *"${id}"*) return 0 ;;
        *) return 1 ;;
    esac
}
