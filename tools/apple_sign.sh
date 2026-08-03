#!/usr/bin/env bash
# apple_sign.sh — Developer-ID signing preconditions and artifact checks,
# sourced by tools/release.sh.
#
# These checks decide whether a --public cut is Developer-ID signed or quietly
# ad-hoc signed, so they live here as functions rather than inline in the
# orchestrator: tools/apple_sign.test.sh exercises them directly, with no part of
# the release path running. Same split as tools/vulncheck.sh.
#
# Two questions, both needed:
#   "can this machine sign?"   load_apple_account, resolve_sign_identity,
#                              sign_identity_reachable
#   "is this FILE signed?"     is_macho, developer_id_signed,
#                              assert_payload_developer_id_signed

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

# ---------------------------------------------------------------------------
# Is this FILE signed? — the third way a --public cut shipped ad-hoc signed.
#
# The predicates above answer "can this machine sign?". These answer "is this
# artifact signed?", which nothing asked before Apple's notary did. release.sh
# caches the bundled `burrowee` dispatcher under a key derived from the
# dispatcher SOURCE (versions/burrowee.stamp) — signing mode is not part of that
# key, and both modes write into the same directory. A --dry-run (the documented
# pre-cut validation step) or any ordinary cut leaves an AD-HOC signed dispatcher
# there, and a mere-existence cache handed it to the --public cut that followed.
# Apple rejected the edge zip with exactly three complaints:
#
#     The binary is not signed with a valid Developer ID certificate.
#     The signature does not include a secure timestamp.
#     The executable does not have the hardened runtime enabled.
#
# So there is one check per complaint below. Same class as the two weaknesses
# c21c081 closed: a public release ships ad-hoc rather than Developer-ID signed
# while the operator believes otherwise, silently.
# ---------------------------------------------------------------------------

# is_macho <file>
# True when <file> begins with a Mach-O or universal-binary magic number, so a
# payload can be walked without asking codesign about shell scripts and HTML.
# Both widths and both endiannesses, plus the fat magic.
#
# `cafebabe` is also the Java class-file magic. Nothing in a Burrowee payload is
# a .class, and mis-reading one would ABORT a cut rather than pass it — the safe
# direction for a signing gate.
is_macho() {
    local file="$1" magic
    [ -f "${file}" ] || return 1
    magic="$(od -An -v -tx1 -N4 "${file}" 2>/dev/null | tr -d '[:space:]')"
    case "${magic}" in
        cefaedfe|cffaedfe|feedface|feedfacf|cafebabe|bebafeca) return 0 ;;
        *) return 1 ;;
    esac
}

# developer_id_signed <file>
# True only when <file> carries a real Developer ID signature: a Developer ID
# Application authority, a Team ID, Apple's secure timestamp, and the hardened
# runtime. One check per notary complaint, so a failure here is the failure Apple
# would report — in milliseconds, off the wire, instead of after a full build and
# an upload.
#
# FAIL CLOSED. Every unresolved state is "not signed": no file, no codesign, a
# codesign that errors (which is what an UNSIGNED binary produces), or output
# missing any one marker. An artifact whose signing state cannot be DETERMINED
# must never be bundled into a --public cut — assuming it was fine is how the
# ad-hoc dispatcher got in.
developer_id_signed() {
    local file="$1" out flag_words
    [ -f "${file}" ] || return 1
    command -v codesign >/dev/null 2>&1 || return 1
    # --display writes its report to stderr; an unsigned binary exits non-zero.
    out="$(codesign --display --verbose=4 "${file}" 2>&1)" || return 1
    case "${out}" in *"Signature=adhoc"*) return 1 ;; esac
    case "${out}" in *"Authority=Developer ID Application: "*) ;; *) return 1 ;; esac
    case "${out}" in *"TeamIdentifier=not set"*) return 1 ;; esac
    case "${out}" in *"TeamIdentifier="*) ;; *) return 1 ;; esac
    # "Timestamp=" is Apple's TRUSTED timestamp. A signature made without the
    # timestamp service prints "Signed Time=" instead — a different field, and
    # the one Apple rejects as "does not include a secure timestamp".
    case "${out}" in *"Timestamp="*) ;; *) return 1 ;; esac
    # Hardened runtime = the CodeDirectory `runtime` flag. codesign prints the
    # flag WORDS in parentheses after the numeric value — `flags=0x10000(runtime)`
    # when it is the only one, a comma-separated list when it is not — so match
    # the word inside the list, not the whole parenthesis. No parenthesis at all
    # (`flags=0x0`) yields an empty list and fails, which is correct.
    flag_words="$(printf '%s\n' "${out}" | sed -n 's/.*flags=[^(]*(\([^)]*\)).*/\1/p' | head -n1)"
    case ",${flag_words}," in
        *,runtime,*) ;;
        *) return 1 ;;
    esac
    return 0
}

# assert_payload_developer_id_signed <dir> <os>
# Pre-assembly gate: every Mach-O about to be zipped must carry a Developer ID
# signature. release.sh calls this only under --apple/--public, once the payload
# dir is populated and before `zip`.
#
# Notarization already catches an ad-hoc binary, but only for darwin, only over
# the network, and only after every target has been built — and the --apple path
# that does not notarize is never covered at all. This asks the same question
# locally, for whatever the payload actually holds. It is a BACKSTOP, not the
# fix: the dispatcher cache is signing-aware now (build_dispatcher in
# tools/release.sh), so nothing should ever reach here unsigned.
#
# The walk is driven by file contents, not by <os>: a darwin binary that ended up
# in a linux payload is checked too. <os> only supplies the emptiness rule — a
# darwin payload with NO Mach-O in it means the assembly went wrong, not that
# there was nothing to check, so that is refused rather than reported as a pass.
assert_payload_developer_id_signed() {
    local dir="$1" os="$2" file rel found=0 bad=0
    if [ ! -d "${dir}" ]; then
        echo "✗ signing check: payload dir does not exist: ${dir}" >&2
        return 1
    fi
    while IFS= read -r -d '' file; do
        is_macho "${file}" || continue
        found=$((found + 1))
        developer_id_signed "${file}" && continue
        rel="${file#"${dir}"/}"
        echo "✗ ${rel}: Mach-O binary is NOT Developer-ID signed — it needs a Developer" >&2
        echo "  ID authority, a Team ID, Apple's secure timestamp and the hardened runtime" >&2
        bad=$((bad + 1))
    done < <(find "${dir}" -type f -print0)
    if [ "${bad}" != 0 ]; then
        echo "✗ refusing to zip ${dir##*/}: ${bad} of ${found} Mach-O binaries would ship" >&2
        echo "  ad-hoc signed, unsigned, or unverifiable under --apple/--public. Apple's" >&2
        echo "  notary rejects exactly this, and a user's Gatekeeper would too." >&2
        return 1
    fi
    if [ "${os}" = darwin ] && [ "${found}" = 0 ]; then
        echo "✗ refusing to zip ${dir##*/}: a darwin payload holding no Mach-O binary at" >&2
        echo "  all — the assembly produced nothing to sign, so nothing was verified." >&2
        return 1
    fi
    local noun="binaries"; [ "${found}" = 1 ] && noun="binary"
    echo "→ signing check: ${found} Mach-O ${noun} in ${dir##*/} — all Developer-ID signed" >&2
}
