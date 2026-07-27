#!/usr/bin/env bash
# apple_sign.test.sh — unit tests for tools/apple_sign.sh.
#
# Exercises the three functions directly with stubbed modernech-sign / security /
# rcodesign on PATH. NO part of the release path runs: release.sh is never
# invoked, nothing is built, signed, notarized or published.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HERE}/apple_sign.sh"

fail=0
check() { # check <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi
}
check_contains() { # check_contains <label> <haystack> <needle>
    case "$2" in
        *"$3"*) echo "ok: $1" ;;
        *) echo "FAIL: $1 — '$2' does not contain '$3'"; fail=1 ;;
    esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
mkdir -p "${STUBS}"
REAL_PATH="${PATH}"

# stub <name> <exit-code> [stdout…] — drop an executable stub into ${STUBS}.
stub() {
    local name="$1" code="$2"; shift 2
    { echo '#!/bin/sh'
      for line in "$@"; do printf 'printf "%%s\\n" %s\n' "'${line}'"; done
      echo "exit ${code}"
    } > "${STUBS}/${name}"
    chmod 0755 "${STUBS}/${name}"
}
# only_stubs — a PATH holding just the stubs plus the coreutils the functions
# need, so `command -v rcodesign` is decided by whether we stubbed it.
only_stubs() { PATH="${STUBS}:/usr/bin:/bin"; }
restore_path() { PATH="${REAL_PATH}"; }

reset_apple_env() {
    unset APPLE_ACCOUNT APPLE_ACCOUNT_DIR APPLE_HOME
}

echo "--- resolve_sign_identity ---------------------------------------------"

# THE REGRESSION. `modernech-sign id` printing nothing is the EXPECTED outcome
# when APPLE_ACCOUNT_DIR points somewhere that does not exist. The old inline
# gate spliced that empty string straight into `grep -q`, becoming `grep -q ""`
# — which matches the first line of any output — so "Developer ID identity
# reachable" passed with no identity at all and the cut continued ad-hoc signed.
stub modernech-sign 0 ""
only_stubs
out="$(resolve_sign_identity modernech-sign 2>&1)"; rc=$?
restore_path
check "empty identity is rejected (rc)" "${rc}" "1"
check_contains "empty identity names the cause" "${out}" "produced no identity"

# Same, when the tool fails outright rather than printing an empty line.
stub modernech-sign 1 ""
only_stubs
out="$(resolve_sign_identity modernech-sign 2>&1)"; rc=$?
restore_path
check "failing 'id' is rejected (rc)" "${rc}" "1"
check_contains "failing 'id' names the cause" "${out}" "produced no identity"

# A real identity passes through verbatim, stderr chatter and all.
stub modernech-sign 0 "Developer ID Application: Acme Corp (AB12CD34EF)"
only_stubs
out="$(resolve_sign_identity modernech-sign 2>/dev/null)"; rc=$?
restore_path
check "real identity (rc)" "${rc}" "0"
check "real identity is printed verbatim" "${out}" "Developer ID Application: Acme Corp (AB12CD34EF)"

# Accepting any NON-EMPTY string was still too loose: a one-line diagnostic or a
# "0 valid identities found" would be spliced into the keychain match as a
# pattern matching nothing, reporting "identity unreachable" for what is really a
# misconfiguration. The accepted shape is the real one — `modernech-sign id`
# prints exactly `Developer ID Application: <Org> (<10-char Team ID>)`.
for bogus in \
    "0 valid identities found" \
    "error: account plugin not found" \
    "Developer ID Application: Acme Corp" \
    "Developer ID Application: Acme Corp (SHORT)" \
    "Apple Development: Acme Corp (AB12CD34EF)" \
    "   " ; do
    stub modernech-sign 0 "${bogus}"
    only_stubs
    out="$(resolve_sign_identity modernech-sign 2>&1)"; rc=$?
    restore_path
    check "non-identity output rejected: '${bogus}'" "${rc}" "1"
done

# Multi-line output is rejected even when one of the lines IS a valid identity:
# the whole blob would become the keychain pattern.
stub modernech-sign 0 "warning: keychain unavailable, falling back" \
                      "Developer ID Application: Acme Corp (AB12CD34EF)"
only_stubs
out="$(resolve_sign_identity modernech-sign 2>&1)"; rc=$?
restore_path
check "multi-line output is rejected (rc)" "${rc}" "1"
check_contains "multi-line output names the cause" "${out}" "printed more than one line"

# Negative control for the tightening: a real identity with surrounding
# whitespace and an organisation containing punctuation must still be ACCEPTED,
# so the pattern is not so strict that it rejects legitimate output.
stub modernech-sign 0 "  Developer ID Application: Acme Corp, L.L.C. (AB12CD34EF)  "
only_stubs
out="$(resolve_sign_identity modernech-sign 2>/dev/null)"; rc=$?
restore_path
check "punctuated org + padding accepted (rc)" "${rc}" "0"
check "padding trimmed" "${out}" "Developer ID Application: Acme Corp, L.L.C. (AB12CD34EF)"

echo "--- sign_identity_reachable -------------------------------------------"

ID="Developer ID Application: Acme Corp (AB12CD34EF)"

# An empty identity must NEVER be reachable — this is the vacuous-pass shape
# reduced to one call. Before the fix the equivalent expression was
# `security … | grep -q ""`, which returns 0 for ANY non-empty output.
stub security 0 "  1) DEADBEEF \"Developer ID Application: Someone Else (ZZ99YY88XX)\"" \
                "     1 valid identities found"
only_stubs
sign_identity_reachable "" ; rc=$?
restore_path
check "empty identity is never reachable" "${rc}" "1"

# A keychain that does not hold this identity is not reachable (rcodesign absent).
stub security 0 "  1) DEADBEEF \"Developer ID Application: Someone Else (ZZ99YY88XX)\"" \
                "     1 valid identities found"
only_stubs
sign_identity_reachable "${ID}"; rc=$?
restore_path
check "identity absent from the keychain" "${rc}" "1"

# A keychain that DOES hold it is reachable — and the parentheses in the
# identity must be matched literally, not as a regex group (grep -F).
stub security 0 "  1) DEADBEEF \"${ID}\"" "     1 valid identities found"
only_stubs
sign_identity_reachable "${ID}"; rc=$?
restore_path
check "identity present in the keychain" "${rc}" "0"

# Repeat the found case many times: `security … | grep -q` used to return 141
# (SIGPIPE) at random when grep short-circuited before the producer finished
# writing — and under release.sh's `set -euo pipefail` that failed a legitimate
# cut. The listing is captured and matched with `case` now, so the result must be
# 0 every single time.
stub security 0 "  1) DEADBEEF \"${ID}\"" \
                "  2) CAFEBABE \"Developer ID Application: Someone Else (ZZ99YY88XX)\"" \
                "  3) F00DF00D \"Developer ID Installer: Acme Corp (AB12CD34EF)\"" \
                "     3 valid identities found"
only_stubs
flaky=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    sign_identity_reachable "${ID}" || flaky=1
done
restore_path
check "found-case is deterministic (no SIGPIPE)" "${flaky}" "0"

# Negative control for literal matching: a REGEX that would match the identity if
# the pattern were interpreted must NOT be treated as a match.
stub security 0 "  1) DEADBEEF \"Developer ID Application: Acme Corp (AB12CD34EF)\""
only_stubs
sign_identity_reachable "Developer ID Application: Acme C.rp .AB12CD34EF."; rc=$?
restore_path
check "pattern is literal, not a regex" "${rc}" "1"

# rcodesign on PATH is sufficient on its own: the disk-key backend never puts
# the identity in a keychain, so an empty keychain must still be reachable.
stub security 0 "     0 valid identities found"
stub rcodesign 0 "rcodesign 0.29.0"
only_stubs
sign_identity_reachable "${ID}"; rc=$?
restore_path
rm -f "${STUBS}/rcodesign"
check "rcodesign backend is sufficient" "${rc}" "0"

echo "--- load_apple_account ------------------------------------------------"

REPO="${WORK}/repo"
mkdir -p "${REPO}/config"
PLUGINS="${WORK}/plugins"
mkdir -p "${PLUGINS}/AcmeCorp" "${PLUGINS}/OtherLLC"

printf '# the project account\n\nAcmeCorp\n' > "${REPO}/config/apple-account"

# Happy path: the account comes from config, every variable is exported.
reset_apple_env
APPLE_HOME="${PLUGINS}" load_apple_account "${REPO}" 2>/dev/null; rc=$?
check "config resolution (rc)" "${rc}" "0"
reset_apple_env
export APPLE_HOME="${PLUGINS}"
load_apple_account "${REPO}" 2>/dev/null
check "APPLE_ACCOUNT from config" "${APPLE_ACCOUNT}" "AcmeCorp"
check "APPLE_ACCOUNT_DIR joined" "${APPLE_ACCOUNT_DIR}" "${PLUGINS}/AcmeCorp"
check "APPLE_HOME exported" "${APPLE_HOME}" "${PLUGINS}"

# THE DIVERGENCE. An operator cutting under a second account exports
# APPLE_ACCOUNT. `rkit build` has always honoured that; the shell unconditionally
# overrode it with config/apple-account, so the SAME export was respected by one
# entry point and silently ignored by the other.
reset_apple_env
export APPLE_HOME="${PLUGINS}"
export APPLE_ACCOUNT="OtherLLC"
load_apple_account "${REPO}" 2>/dev/null
check "preset APPLE_ACCOUNT wins over config" "${APPLE_ACCOUNT}" "OtherLLC"
check "preset account drives the dir" "${APPLE_ACCOUNT_DIR}" "${PLUGINS}/OtherLLC"

# A missing account plugin folder is FATAL, not a warning: Apple signing was
# requested, so continuing yields an ad-hoc signed cut that the operator
# believes is Developer-ID signed and notarized.
reset_apple_env
export APPLE_HOME="${PLUGINS}"
export APPLE_ACCOUNT="NoSuchAccount"
out="$(load_apple_account "${REPO}" 2>&1)"; rc=$?
check "missing plugin folder is fatal (rc)" "${rc}" "1"
check_contains "missing plugin folder is named" "${out}" "account plugin folder points at"
check_contains "missing plugin folder refuses" "${out}" "AD-HOC"

# No config file and no env at all → refuse rather than proceed accountless.
reset_apple_env
export APPLE_HOME="${PLUGINS}"
EMPTY_REPO="${WORK}/empty-repo"
mkdir -p "${EMPTY_REPO}"
out="$(load_apple_account "${EMPTY_REPO}" 2>&1)"; rc=$?
check "no account anywhere is fatal (rc)" "${rc}" "1"
check_contains "no account anywhere is explained" "${out}" "APPLE_ACCOUNT is unresolved"

# APPLE_HOME comes from the repo's own config/apple-home, so a cut needs nothing
# exported. This copy used to default it to a baked $HOME path while the Go twin
# refused to default at all — the two disagreed about where plugins live, and
# $HOME is unset under launchd/cron/a detached session anyway.
reset_apple_env
HOME_REPO="${WORK}/home-repo"
mkdir -p "${HOME_REPO}/config"
printf 'AcmeCorp\n' > "${HOME_REPO}/config/apple-account"
printf '# where the plugins live\n\n%s\n' "${PLUGINS}" > "${HOME_REPO}/config/apple-home"
load_apple_account "${HOME_REPO}" 2>/dev/null; rc=$?
check "apple-home config resolution (rc)" "${rc}" "0"
check "APPLE_HOME from config" "${APPLE_HOME}" "${PLUGINS}"
check "APPLE_ACCOUNT_DIR joined from config home" "${APPLE_ACCOUNT_DIR}" "${PLUGINS}/AcmeCorp"

# An exported APPLE_HOME still wins over the file — same precedence as account.
reset_apple_env
export APPLE_HOME="${PLUGINS}"
load_apple_account "${HOME_REPO}" 2>/dev/null
check "preset APPLE_HOME wins over config" "${APPLE_HOME}" "${PLUGINS}"

# No APPLE_HOME anywhere is fatal, and the error names every way to supply it.
reset_apple_env
out="$(load_apple_account "${REPO}" 2>&1)"; rc=$?
check "unresolved APPLE_HOME is fatal (rc)" "${rc}" "1"
check_contains "unresolved APPLE_HOME is explained" "${out}" "APPLE_HOME is unresolved"
check_contains "unresolved APPLE_HOME names the file" "${out}" "config/apple-home"
check_contains "unresolved APPLE_HOME names the env var" "${out}" "\$APPLE_HOME"
check_contains "unresolved APPLE_HOME names the dir escape" "${out}" "\$APPLE_ACCOUNT_DIR"

# A relative APPLE_HOME is refused rather than joined into a relative dir.
reset_apple_env
export APPLE_HOME="Workstation/Apple"
out="$(load_apple_account "${REPO}" 2>&1)"; rc=$?
check "relative APPLE_HOME is fatal (rc)" "${rc}" "1"
check_contains "relative APPLE_HOME is explained" "${out}" "not an absolute path"

# APPLE_ACCOUNT_DIR settles both and consults no config — but a stale one
# pointing at a folder that no longer exists must abort, not sail through.
reset_apple_env
export APPLE_ACCOUNT_DIR="${PLUGINS}/AcmeCorp"
load_apple_account "${WORK}/empty-repo" 2>/dev/null; rc=$?
check "APPLE_ACCOUNT_DIR alone resolves (rc)" "${rc}" "0"
reset_apple_env
export APPLE_ACCOUNT_DIR="${PLUGINS}/GoneAway"
out="$(load_apple_account "${WORK}/empty-repo" 2>&1)"; rc=$?
check "stale APPLE_ACCOUNT_DIR is fatal (rc)" "${rc}" "1"
check_contains "stale APPLE_ACCOUNT_DIR is named" "${out}" "APPLE_ACCOUNT_DIR points at"

# A config holding only comments/blanks is the same unresolved state.
reset_apple_env
export APPLE_HOME="${PLUGINS}"
BLANK_REPO="${WORK}/blank-repo"
mkdir -p "${BLANK_REPO}/config"
printf '# nothing here\n\n   \n' > "${BLANK_REPO}/config/apple-account"
out="$(load_apple_account "${BLANK_REPO}" 2>&1)"; rc=$?
check "comment-only config is fatal (rc)" "${rc}" "1"
check_contains "comment-only config is explained" "${out}" "APPLE_ACCOUNT is unresolved"

echo
if [ "${fail}" = 0 ]; then echo "ALL OK"; else echo "TESTS FAILED"; exit 1; fi
