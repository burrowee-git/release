#!/usr/bin/env bash
# apple_sign.test.sh — unit tests for tools/apple_sign.sh.
#
# Exercises every function directly with stubbed modernech-sign / security /
# rcodesign / codesign on PATH. NO part of the release path runs: release.sh is
# never invoked, nothing is built, signed, notarized or published, and the
# "binaries" are four magic bytes plus a marker the codesign stub reads.
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

echo "--- require_desktop_session -------------------------------------------"

# require_desktop_session reads exactly three things — `launchctl managername`,
# `id -u` and $SSH_CONNECTION — so stubs decide all three and nothing about the
# real session leaks in. The PATH here holds ONLY the stubs, with no /bin: the
# real launchctl lives at /bin/launchctl, and the "launchctl is absent" case
# below has to actually mean absent. Everything else the function touches
# (`echo`, `[`) is a shell builtin.
only_session_stubs() { PATH="${STUBS}"; }
# A non-root, non-SSH, unbypassed baseline, so each case below changes exactly
# one thing.
session_baseline() {
    unset SSH_CONNECTION BURROWEE_ALLOW_ANY_SESSION
    stub id 0 "501"
}

# The desktop session: accepted, and silent — this guard runs on every --public
# cut, so a chatty pass would train the operator to ignore it.
session_baseline
stub launchctl 0 "Aqua"
only_session_stubs
out="$(require_desktop_session 2>&1)"; rc=$?
restore_path
check "Aqua session accepted (rc)" "${rc}" "0"
check "Aqua session says nothing" "${out}" ""

# THE BUG THIS GUARD EXISTS FOR. A daemon-hosted shell signs fine and then
# SIGTRAPs at notarize with no submission id, ten minutes and every platform
# later. The refusal has to name the domain it actually saw AND the one it
# needs, or the operator cannot tell a misread session from a wrong one.
session_baseline
stub launchctl 0 "System"
only_session_stubs
out="$(require_desktop_session 2>&1)"; rc=$?
restore_path
check "System domain refused (rc)" "${rc}" "1"
check_contains "System refusal names the domain it got" "${out}" "managername = System"
check_contains "System refusal names the domain it needs" "${out}" "need Aqua"
check_contains "System refusal names the way out" "${out}" "tools/release.command"

session_baseline
stub launchctl 0 "Background"
only_session_stubs
require_desktop_session >/dev/null 2>&1; rc=$?
restore_path
check "Background domain refused (rc)" "${rc}" "1"

# FAIL CLOSED when the question cannot be answered. `launchctl managername`
# absent or failing leaves the domain UNKNOWN, and unknown is not Aqua: a guard
# that treats "I could not tell" as "go ahead" is the vacuous-pass shape, and
# this one guards a ten-minute failure.
session_baseline
rm -f "${STUBS}/launchctl"
only_session_stubs
out="$(require_desktop_session 2>&1)"; rc=$?
restore_path
check "absent launchctl refuses (rc)" "${rc}" "1"
check_contains "absent launchctl reads as unknown" "${out}" "managername = unknown"

session_baseline
stub launchctl 1
only_session_stubs
out="$(require_desktop_session 2>&1)"; rc=$?
restore_path
check "failing launchctl refuses (rc)" "${rc}" "1"
check_contains "failing launchctl reads as unknown" "${out}" "managername = unknown"

# launchctl exiting 0 with nothing to say is the third undeterminable shape —
# and the one that survives a `[ "${domain}" != "Aqua" ]` written as a `case`
# with a permissive default.
session_baseline
stub launchctl 0 ""
only_session_stubs
out="$(require_desktop_session 2>&1)"; rc=$?
restore_path
check "empty launchctl output refuses (rc)" "${rc}" "1"
check_contains "empty launchctl output still names Aqua" "${out}" "need Aqua"

# Aqua is necessary, not sufficient. A sudo'd cut inherits the desktop's Aqua
# domain and then notarizes against ROOT's keychain — no stored notary
# credential, and the failure looks like a credential problem, not a whoami one.
# `id` is stubbed; nothing here runs as root or asks for privilege.
session_baseline
stub id 0 "0"
stub launchctl 0 "Aqua"
only_session_stubs
out="$(require_desktop_session 2>&1)"; rc=$?
restore_path
check "root refused even in Aqua (rc)" "${rc}" "1"
check_contains "root refusal names the keychain" "${out}" "root's keychain"

# Same shape from the other side: `launchctl asuser <uid>` from an SSH session
# lands in the user's GUI domain and reports Aqua while still having no console
# security session.
session_baseline
stub launchctl 0 "Aqua"
# RFC 5737 documentation addresses — the function reads only whether the
# variable is non-empty, never what is in it.
export SSH_CONNECTION="203.0.113.9 51234 203.0.113.1 22"
only_session_stubs
out="$(require_desktop_session 2>&1)"; rc=$?
restore_path
unset SSH_CONNECTION
check "SSH session refused even in Aqua (rc)" "${rc}" "1"
check_contains "SSH refusal names the missing console session" "${out}" "console security session"

# The documented escape hatch, for a machine whose session model this check
# misreads. It must pass — and it must SAY so on stderr, because the next thing
# it can produce is the SIGTRAP this guard was written to explain.
session_baseline
stub launchctl 0 "System"
export BURROWEE_ALLOW_ANY_SESSION=1
only_session_stubs
out="$(require_desktop_session 2>&1)"; rc=$?
restore_path
unset BURROWEE_ALLOW_ANY_SESSION
check "BURROWEE_ALLOW_ANY_SESSION=1 passes a System session (rc)" "${rc}" "0"
check_contains "the bypass warns that it is a bypass" "${out}" "BURROWEE_ALLOW_ANY_SESSION=1"
check_contains "the bypass names what it risks" "${out}" "SIGTRAP"

# Leave no session stubs behind: every section below runs with /usr/bin and /bin
# on PATH, where a stray `id` or `launchctl` stub would be found first.
rm -f "${STUBS}/launchctl" "${STUBS}/id"
unset SSH_CONNECTION BURROWEE_ALLOW_ANY_SESSION

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

echo "--- is_macho / developer_id_signed / assert_payload_developer_id_signed --"

# A stub codesign that answers per-FILE, driven by a marker written into the file
# after its magic bytes. One stub covers every signing shape below, and the two
# realistic reports are the REAL output of `codesign -dv --verbose=4` on an
# ad-hoc signed and a Developer-ID signed `burrowee` dispatcher.
#
# LC_ALL=C on the marker grep: Mach-O magic is not valid UTF-8, and grep in a
# UTF-8 locale refuses to match inside a file it cannot decode — returning 1 with
# no output, which would silently read as "marker absent".
cat > "${STUBS}/codesign" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
target=""
for a in "$@"; do case "${a}" in -*) ;; *) target="${a}" ;; esac; done
[ -f "${target}" ] || { echo "${target}: No such file or directory" >&2; exit 1; }
report() {
    printf 'Identifier=burrowee\nFormat=Mach-O thin (arm64)\n' >&2
    printf 'CodeDirectory v=20500 size=20084 %s hashes=622+2 location=embedded\n' "$1" >&2
    printf 'Signature size=8970\n' >&2
    printf 'Authority=%s\n' "$2" >&2
    printf 'Authority=Developer ID Certification Authority\nAuthority=Apple Root CA\n' >&2
    printf '%s\n' "$3" >&2
    printf 'Info.plist=not bound\nTeamIdentifier=%s\nSealed Resources=none\n' "$4" >&2
}
marker() { LC_ALL=C grep -q "$1" "${target}" 2>/dev/null; }
if marker DEVID;    then report 'flags=0x10000(runtime)' 'Developer ID Application: Acme Corp (AB12CD34EF)' 'Timestamp=Aug 2, 2026 at 10:46:06 AM' 'AB12CD34EF'; exit 0; fi
if marker FLAGLIST; then report 'flags=0x12000(library-validation,runtime)' 'Developer ID Application: Acme Corp (AB12CD34EF)' 'Timestamp=Aug 2, 2026 at 10:46:06 AM' 'AB12CD34EF'; exit 0; fi
if marker NOSTAMP;  then report 'flags=0x10000(runtime)' 'Developer ID Application: Acme Corp (AB12CD34EF)' 'Signed Time=Aug 2, 2026 at 10:46:06 AM' 'AB12CD34EF'; exit 0; fi
if marker NORUNTIME; then report 'flags=0x0' 'Developer ID Application: Acme Corp (AB12CD34EF)' 'Timestamp=Aug 2, 2026 at 10:46:06 AM' 'AB12CD34EF'; exit 0; fi
if marker NOTEAM;   then report 'flags=0x10000(runtime)' 'Developer ID Application: Acme Corp (AB12CD34EF)' 'Timestamp=Aug 2, 2026 at 10:46:06 AM' 'not set'; exit 0; fi
if marker APPLEDEV; then report 'flags=0x10000(runtime)' 'Apple Development: Acme Corp (AB12CD34EF)' 'Timestamp=Aug 2, 2026 at 10:46:06 AM' 'AB12CD34EF'; exit 0; fi
if marker ADHOC; then
    printf 'Identifier=burrowee-5555494401446aec641a3c14dfb5574a1f06abc1\n' >&2
    printf 'Format=Mach-O thin (arm64)\n' >&2
    printf 'CodeDirectory v=20400 size=5194 flags=0x2(adhoc) hashes=156+2 location=embedded\n' >&2
    printf 'Signature=adhoc\nInfo.plist=not bound\nTeamIdentifier=not set\n' >&2
    exit 0
fi
echo "${target}: code object is not signed at all" >&2
exit 1
STUB
chmod 0755 "${STUBS}/codesign"

BINS="${WORK}/bins"
mkdir -p "${BINS}"
# write_file <name> <magic-octal> [marker] — a fixture with real magic bytes.
write_file() {
    # shellcheck disable=SC2059  # $2 IS the format string — it carries the octal magic-byte escapes.
    { printf "$2"; printf '%s\n' "${3:-}"; } > "${BINS}/$1"
}
MACHO='\317\372\355\376'   # 64-bit little-endian Mach-O
FAT='\312\376\272\276'     # universal binary
ELF='\177ELF'

write_file macho.bin  "${MACHO}" DEVID
write_file fat.bin    "${FAT}"   DEVID
write_file elf.bin    "${ELF}"   DEVID
printf '#!/bin/sh\necho hi\n' > "${BINS}/install.sh"
printf '<html><body>hi</body></html>\n' > "${BINS}/cover.html"

only_stubs
check "is_macho: thin Mach-O" "$(is_macho "${BINS}/macho.bin"      && echo y || echo n)" "y"
check "is_macho: universal"   "$(is_macho "${BINS}/fat.bin"        && echo y || echo n)" "y"
check "is_macho: ELF"         "$(is_macho "${BINS}/elf.bin"        && echo y || echo n)" "n"
check "is_macho: shell script" "$(is_macho "${BINS}/install.sh"    && echo y || echo n)" "n"
check "is_macho: html"        "$(is_macho "${BINS}/cover.html"     && echo y || echo n)" "n"
check "is_macho: missing file" "$(is_macho "${BINS}/nope"          && echo y || echo n)" "n"
restore_path

# THE REGRESSION. Apple rejected a --public cut with three complaints about the
# bundled dispatcher — not Developer-ID signed, no secure timestamp, no hardened
# runtime — because a --dry-run had left an AD-HOC signed binary in the cache
# directory the cut then reused. There is one case below per complaint, plus the
# two states where the answer is UNKNOWN, which must read as "not signed".
for want_marker in \
    "0 DEVID" \
    "0 FLAGLIST" \
    "1 ADHOC" \
    "1 NOSTAMP" \
    "1 NORUNTIME" \
    "1 NOTEAM" \
    "1 APPLEDEV" \
    "1 UNSIGNED" ; do
    want="${want_marker%% *}"; marker="${want_marker#* }"
    write_file "case.bin" "${MACHO}" "${marker}"
    only_stubs
    developer_id_signed "${BINS}/case.bin"; rc=$?
    restore_path
    check "developer_id_signed: ${marker} → rc ${want}" "${rc}" "${want}"
done

# FAIL CLOSED on the two ways the question cannot be answered at all.
write_file "case.bin" "${MACHO}" DEVID
only_stubs
developer_id_signed "${BINS}/nope"; rc=$?
restore_path
check "developer_id_signed: missing file is not signed" "${rc}" "1"

# No codesign on PATH — the state is undeterminable, so it is "not signed".
mv "${STUBS}/codesign" "${WORK}/codesign.parked"
PATH="${STUBS}"
developer_id_signed "${BINS}/case.bin"; rc=$?
restore_path
mv "${WORK}/codesign.parked" "${STUBS}/codesign"
check "developer_id_signed: no codesign is not signed" "${rc}" "1"

# ---- assert_payload_developer_id_signed: the pre-assembly gate -------------
# Notarization catches an ad-hoc binary only for darwin, only over the network,
# and only after every target is built — and --apple without --public never
# notarizes at all. This asks the same question locally, over whatever the
# payload actually holds.
PAY="${WORK}/payload"
new_payload() { rm -rf "${PAY}"; mkdir -p "${PAY}/covers"; }
pay_file() {
    # shellcheck disable=SC2059  # $2 IS the format string — octal magic-byte escapes.
    { printf "$2"; printf '%s\n' "${3:-}"; } > "${PAY}/$1"
}

# A whole darwin payload: three signed Mach-Os plus the non-binary payload files.
new_payload
pay_file burrowee-edge "${MACHO}" DEVID
pay_file burrowee-edge-cli "${MACHO}" DEVID
pay_file burrowee "${MACHO}" DEVID
printf '#!/bin/sh\n' > "${PAY}/install.sh"
printf '<html></html>\n' > "${PAY}/covers/default.html"
only_stubs
out="$(assert_payload_developer_id_signed "${PAY}" darwin 2>&1)"; rc=$?
restore_path
check "payload: all signed (rc)" "${rc}" "0"
check_contains "payload: reports the count it checked" "${out}" "3 Mach-O binaries"

# ONE ad-hoc binary among signed ones is the shipped bug: the dispatcher.
pay_file burrowee "${MACHO}" ADHOC
only_stubs
out="$(assert_payload_developer_id_signed "${PAY}" darwin 2>&1)"; rc=$?
restore_path
check "payload: one ad-hoc binary is fatal (rc)" "${rc}" "1"
check_contains "payload: names the offending file" "${out}" "burrowee: Mach-O binary is NOT Developer-ID signed"
check_contains "payload: counts it" "${out}" "1 of 3"

# A darwin payload with no Mach-O at all is an assembly failure, not a pass:
# reporting "0 binaries, all fine" is how a vacuous gate reads.
new_payload
printf '#!/bin/sh\n' > "${PAY}/install.sh"
only_stubs
out="$(assert_payload_developer_id_signed "${PAY}" darwin 2>&1)"; rc=$?
restore_path
check "payload: empty darwin payload is fatal (rc)" "${rc}" "1"
check_contains "payload: empty darwin payload is explained" "${out}" "no Mach-O binary"

# The same payload for LINUX is fine — there is nothing to code-sign there.
only_stubs
assert_payload_developer_id_signed "${PAY}" linux >/dev/null 2>&1; rc=$?
restore_path
check "payload: script-only linux payload passes" "${rc}" "0"

# But the walk is driven by file CONTENTS, not by <os>: a darwin binary that ends
# up in a linux payload is still checked.
pay_file burrowee "${MACHO}" ADHOC
only_stubs
assert_payload_developer_id_signed "${PAY}" linux >/dev/null 2>&1; rc=$?
restore_path
check "payload: ad-hoc Mach-O in a linux payload is still fatal" "${rc}" "1"

# A payload dir that isn't there is refused rather than treated as empty.
only_stubs
out="$(assert_payload_developer_id_signed "${WORK}/no-such-payload" darwin 2>&1)"; rc=$?
restore_path
check "payload: missing dir is fatal (rc)" "${rc}" "1"
check_contains "payload: missing dir is explained" "${out}" "does not exist"

echo
if [ "${fail}" = 0 ]; then echo "ALL OK"; else echo "TESTS FAILED"; exit 1; fi
