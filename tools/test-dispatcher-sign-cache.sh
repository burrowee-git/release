#!/usr/bin/env bash
# test-dispatcher-sign-cache.sh — prove build_dispatcher() (release.sh) never
# reuses a cached dispatcher that is not Developer-ID signed when Apple signing
# was requested.
#
# THE BUG. The cache key is the dispatcher SOURCE (DISP_STAMP). Signing mode is
# not part of it and both modes write into the same directory, so
# `if [ -x "${out}/burrowee" ]; then return 0; fi` reused whatever was there.
# A `--dry-run` — the documented way to validate a cut before making it — leaves
# an AD-HOC signed dispatcher under that key, and the --public cut minutes later
# copied it into every component zip as `burrowee`. Apple's notary rejected the
# edge zip for that exact file. Case (f) below is that sequence, end to end.
#
# release.sh cannot be sourced whole (it parses $1, prompts, and exits 2 with no
# args, all before build_dispatcher's definition), so the function's source text
# is pulled out by line-anchored brace-depth extraction into a sourceable file —
# the same trick as tools/test-dispatcher-stamp-freeze.sh.
#
# Nothing real is built, signed or published: tools/build.sh and codesign are
# both STUBBED, the dispatcher "binaries" are four magic bytes plus a marker, and
# neither the real burrowee worktree nor this repo's dist/.dispatcher cache is
# touched. No Apple credentials, no keychain, no network.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ DISPATCHER-SIGN-CACHE TEST FAILED: %s\n' "$*" >&2; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-dispatcher-sign-cache-XXXXXX")"
cleanup() { rm -rf "${W}"; }
trap cleanup EXIT INT TERM

# ---- (1) extract build_dispatcher() from release.sh, by text ---------------
extract_build_dispatcher() {
    local out="$1"
    python3 - "${REPO_ROOT}/tools/release.sh" "${out}" <<'PYEOF'
import sys

src_path, out_path = sys.argv[1], sys.argv[2]
lines = open(src_path).readlines()

in_func = False
depth = 0
result = []

for line in lines:
    if not in_func:
        if line.startswith('build_dispatcher() {'):
            in_func = True
            depth = 0
        else:
            continue

    result.append(line)
    depth += line.count('{') - line.count('}')
    if depth <= 0 and len(result) > 2:
        break  # closing brace of build_dispatcher reached

open(out_path, 'w').writelines(result)
PYEOF
}

HELPER="${W}/build_dispatcher.sh"
extract_build_dispatcher "${HELPER}"
grep -q '^build_dispatcher() {' "${HELPER}" \
    || die "extraction failed — build_dispatcher() not found in ${HELPER}"
grep -q '^}$' "${HELPER}" \
    || die "extraction failed — no closing brace captured in ${HELPER}"

# ---- (2) stub tools/build.sh: records the call, then writes a Mach-O-shaped
#          "binary" whose body records the mode it was built in ---------------
FAKE_REPO="${W}/repo-root"
mkdir -p "${FAKE_REPO}/tools"
CALL_LOG="${W}/build.calls"
: > "${CALL_LOG}"
cat > "${FAKE_REPO}/tools/build.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s-%s%s\n' "${COMP}" "${TARGETOS}" "${TARGETARCH}" "${VARIANT:+ ${VARIANT}}" >> "${CALL_LOG}"
mkdir -p "${OUT_DIR}"
{
    printf '\317\372\355\376'                       # Mach-O 64-bit LE magic
    if [ -n "${APPLE_SIGN:-}" ]; then printf 'DEVID\n'; else printf 'ADHOC\n'; fi
} > "${OUT_DIR}/burrowee"
chmod 0755 "${OUT_DIR}/burrowee"
STUB
chmod 0755 "${FAKE_REPO}/tools/build.sh"

# ---- (3) stub codesign --display: real recorded output, chosen by the marker
#          inside the target file. No marker = unsigned: codesign exits 1, which
#          is the signing state that CANNOT BE DETERMINED. -------------------
#
# LC_ALL=C on every marker grep, here and in marker_of below: the fixture's first
# four bytes are Mach-O magic, which is not valid UTF-8, and grep in a UTF-8
# locale refuses to match inside a file it cannot decode — it returns 1 with no
# output, which would silently read as "marker absent". C locale matches bytes.
STUBS="${W}/stubs"
mkdir -p "${STUBS}"
cat > "${STUBS}/codesign" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
target=""
for a in "$@"; do case "${a}" in -*) ;; *) target="${a}" ;; esac; done
[ -f "${target}" ] || { echo "${target}: No such file or directory" >&2; exit 1; }
if LC_ALL=C grep -q DEVID "${target}" 2>/dev/null; then
    cat >&2 <<'OUT'
Identifier=burrowee
Format=Mach-O thin (arm64)
CodeDirectory v=20500 size=20084 flags=0x10000(runtime) hashes=622+2 location=embedded
Signature size=8970
Authority=Developer ID Application: Acme Corp (AB12CD34EF)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Aug 2, 2026 at 10:46:06 AM
Info.plist=not bound
TeamIdentifier=AB12CD34EF
Runtime Version=12.0.0
Sealed Resources=none
OUT
    exit 0
fi
if LC_ALL=C grep -q ADHOC "${target}" 2>/dev/null; then
    cat >&2 <<'OUT'
Identifier=burrowee-5555494401446aec641a3c14dfb5574a1f06abc1
Format=Mach-O thin (arm64)
CodeDirectory v=20400 size=5194 flags=0x2(adhoc) hashes=156+2 location=embedded
Signature=adhoc
Info.plist=not bound
TeamIdentifier=not set
Sealed Resources=none
OUT
    exit 0
fi
echo "${target}: code object is not signed at all" >&2
exit 1
STUB
chmod 0755 "${STUBS}/codesign"

# ---- (4) harness ----------------------------------------------------------
CACHE="${W}/dispatcher-cache"
FAKE_SRC="${W}/dispatcher-src"      # never the real burrowee checkout
mkdir -p "${FAKE_SRC}"
REPO_ROOT_REAL="${REPO_ROOT}"       # REPO_ROOT is reassigned inside the subshell

# run_build_dispatcher <apple_sign> <os> <arch> [<variant>] — build_dispatcher
# in a clean subshell, on a PATH holding only the stubs plus coreutils.
run_build_dispatcher() {
    # shellcheck disable=SC2034  # every var below is read by build_dispatcher in ${HELPER}, sourced at the end of this subshell.
    (
        set -euo pipefail
        PATH="${STUBS}:/usr/bin:/bin"
        export CALL_LOG
        REPO_ROOT="${FAKE_REPO}"
        SRC_DISPATCHER="${FAKE_SRC}"
        DISP_STAMP="v9.9.9.2020.01.01.deadbeef"
        DISP_DIR="${CACHE}"
        GO_BIN="/nonexistent/go"    # the stub build.sh never invokes go
        export APPLE_SIGN="$1"      # release.sh exports it; build.sh reads it
        # shellcheck source=/dev/null
        source "${REPO_ROOT_REAL}/tools/apple_sign.sh"
        # shellcheck disable=SC1090
        plat_of() { printf '%s-%s%s' "$1" "$2" "${3:+-$3}"; }
        # shellcheck source=/dev/null
        source "${HELPER}"
        build_dispatcher "$2" "$3" "${4:-}"
    )
}

# plant <os-arch> <magic-octal> <marker> — pre-populate the cache as an earlier
# build would have left it.
plant() {
    local d="${CACHE}/$1"
    rm -rf "${d}"; mkdir -p "${d}"
    # shellcheck disable=SC2059  # $2 IS the format string — it carries the octal magic-byte escapes.
    { printf "$2"; printf '%s\n' "$3"; } > "${d}/burrowee"
    chmod 0755 "${d}/burrowee"
}
MACHO='\317\372\355\376'
ELF='\177ELF'

marker_of() {
    if LC_ALL=C grep -q DEVID "${CACHE}/$1/burrowee" 2>/dev/null; then echo DEVID
    elif LC_ALL=C grep -q ADHOC "${CACHE}/$1/burrowee" 2>/dev/null; then echo ADHOC
    else echo OTHER; fi
}
builds() { wc -l < "${CALL_LOG}" | tr -d ' '; }
reset_builds() { : > "${CALL_LOG}"; }

# ---- (a) ad-hoc cached artifact under APPLE_SIGN → rebuilt ----------------
say "(a) cached ad-hoc dispatcher + APPLE_SIGN → rebuild + re-sign"
plant darwin-arm64 "${MACHO}" ADHOC
reset_builds
out="$(run_build_dispatcher 1 darwin arm64 2>&1)" || die "(a) build_dispatcher failed: ${out}"
[ "$(builds)" = 1 ] || die "(a) expected 1 rebuild, build.sh was called $(builds) time(s) — the ad-hoc binary was REUSED"
[ "$(marker_of darwin-arm64)" = DEVID ] \
    || die "(a) cache still holds a $(marker_of darwin-arm64) binary after the rebuild"
case "${out}" in
    *"not Developer-ID signed"*) ;;
    *) die "(a) the rebuild was silent — operator must be told why: '${out}'" ;;
esac
echo "PASS (a): ad-hoc cache entry rebuilt and re-signed, and said so"

# ---- (b) Developer-ID cached artifact under APPLE_SIGN → reused -----------
say "(b) cached Developer-ID dispatcher + APPLE_SIGN → reuse (no rebuild)"
plant darwin-arm64 "${MACHO}" DEVID
reset_builds
run_build_dispatcher 1 darwin arm64 >/dev/null 2>&1 || die "(b) build_dispatcher failed"
[ "$(builds)" = 0 ] || die "(b) a correctly signed cache entry was rebuilt — the cache no longer caches"
echo "PASS (b): Developer-ID cache entry reused"

# ---- (c) no APPLE_SIGN → the cache keeps its original meaning -------------
say "(c) cached ad-hoc dispatcher, no APPLE_SIGN → reuse (nothing to prove)"
plant darwin-arm64 "${MACHO}" ADHOC
reset_builds
run_build_dispatcher "" darwin arm64 >/dev/null 2>&1 || die "(c) build_dispatcher failed"
[ "$(builds)" = 0 ] || die "(c) a dev build rebuilt an ad-hoc cache entry — one build per target per run is the point"
[ "$(marker_of darwin-arm64)" = ADHOC ] || die "(c) the ad-hoc entry was replaced in a non-Apple build"
echo "PASS (c): non-Apple mode still reuses"

# ---- (d) linux target under APPLE_SIGN → reused (nothing is code-signed) --
say "(d) cached linux dispatcher + APPLE_SIGN → reuse (linux is never signed)"
plant linux-amd64 "${ELF}" ADHOC
reset_builds
run_build_dispatcher 1 linux amd64 >/dev/null 2>&1 || die "(d) build_dispatcher failed"
[ "$(builds)" = 0 ] || die "(d) a linux cache entry was rebuilt for want of a signature it can never carry"
echo "PASS (d): linux cache entry reused"

# ---- (e) FAIL CLOSED: unverifiable artifact under APPLE_SIGN → rebuilt ----
say "(e) cached UNSIGNED dispatcher (codesign errors) + APPLE_SIGN → rebuild"
plant darwin-arm64 "${MACHO}" MYSTERY
reset_builds
run_build_dispatcher 1 darwin arm64 >/dev/null 2>&1 || die "(e) build_dispatcher failed"
[ "$(builds)" = 1 ] || die "(e) an artifact whose signing state could not be DETERMINED was reused — must fail closed"
[ "$(marker_of darwin-arm64)" = DEVID ] || die "(e) cache still holds the unverifiable binary"
echo "PASS (e): undeterminable signing state treated as unsigned"

# ---- (f) THE REPORTED SEQUENCE: --dry-run, then a --public cut ------------
say "(f) --dry-run then --public, same cache — the sequence that failed notarization"
rm -rf "${CACHE}"
reset_builds
run_build_dispatcher "" darwin arm64 >/dev/null 2>&1 || die "(f) dry-run leg failed"
[ "$(marker_of darwin-arm64)" = ADHOC ] \
    || die "(f) the dry-run leg did not leave an ad-hoc binary — the fixture no longer reproduces the bug"
run_build_dispatcher 1 darwin arm64 >/dev/null 2>&1 || die "(f) public leg failed"
[ "$(marker_of darwin-arm64)" = DEVID ] \
    || die "(f) the --public cut bundled the dry-run's $(marker_of darwin-arm64) dispatcher — THE BUG"
[ "$(builds)" = 2 ] || die "(f) expected 2 builds (dry-run + re-sign), got $(builds)"
echo "PASS (f): the --public cut rebuilt the dry-run's ad-hoc dispatcher"


# ---- (g) darwin/amd64 legacy variant caches SEPARATELY from stock darwin-amd64
# THE BUG THIS GUARDS: build_dispatcher's cache key used to be "${os}-${arch}"
# with the variant silently dropped, so building darwin/amd64 stock and then
# darwin/amd64/legacy would hit the SAME cache dir — the second call would
# see the first build's cached binary as "already built" and reuse it
# verbatim, shipping a non-legacy dispatcher inside the legacy zip (the exact
# crash-before-main defect this platform exists to fix). A correct cache key
# must produce two builds and two distinct cache directories.
say "(g) darwin/amd64 legacy variant caches separately from stock darwin-amd64"
rm -rf "${CACHE}"
reset_builds
run_build_dispatcher "" darwin amd64 >/dev/null 2>&1 || die "(g) darwin-amd64 (stock) build failed"
run_build_dispatcher "" darwin amd64 legacy >/dev/null 2>&1 || die "(g) darwin-amd64-legacy build failed"
[ "$(builds)" = 2 ] \
    || die "(g) expected 2 separate builds (stock + legacy), got $(builds) — the legacy variant reused the stock cache entry"
[ -f "${CACHE}/darwin-amd64/burrowee" ] \
    || die "(g) stock cache dir missing: ${CACHE}/darwin-amd64"
[ -f "${CACHE}/darwin-amd64-legacy/burrowee" ] \
    || die "(g) legacy cache dir missing: ${CACHE}/darwin-amd64-legacy — cache key did not include the variant"
grep -q '^burrowee darwin-amd64$' "${CALL_LOG}" \
    || die "(g) stock build.sh call was not logged as plain darwin-amd64 (no VARIANT). Log:\n$(cat "${CALL_LOG}")"
grep -q '^burrowee darwin-amd64 legacy$' "${CALL_LOG}" \
    || die "(g) legacy build.sh call did not receive VARIANT=legacy. Log:\n$(cat "${CALL_LOG}")"
echo "PASS (g): darwin-amd64-legacy cached separately from darwin-amd64, and VARIANT threaded to build.sh"

echo
echo "✓ ALL DISPATCHER-SIGN-CACHE TESTS PASSED"
