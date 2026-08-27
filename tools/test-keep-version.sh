#!/usr/bin/env bash
# test-keep-version.sh — prove release.sh's --keep-version flag: keep
# versions/<comp> EXACTLY as it is (no bump of any kind) while still minting a
# FRESH stamp over the component's current commit, refuse when that stamp
# already has a tag, and refuse to combine with the flags that move the version.
#
# Two halves, because the behaviour lives in two places:
#
#   (A) resolve_comp_stamp()/assert_stamp_untagged() — extracted by
#       line-anchored, brace-depth extraction into a sourceable file (the
#       pattern test-comp-version-freeze.sh and test-dispatcher-stamp-freeze.sh
#       already use; release.sh is not designed to be sourced whole), then run
#       against a fully isolated fake REPO_ROOT + fake component source
#       worktree — never a real Burrowee/<comp> checkout, never this repo's own
#       versions/<comp>.stamp, never this repo's tags.
#
#   (B) the mutual-exclusion refusals — exercised through the REAL entry point
#       (`bash tools/release.sh …`), because that is the only thing that proves
#       the refusal fires before the cut's pre-flight rather than in some
#       function a user cannot reach. Every case here is --dry-run and exits 2
#       during argument parsing: no build, no key, no network, no writes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"
# Resolved once, up here: the (f)/(g) cases below run the real script AFTER
# run_resolve's subshell has shadowed REPO_ROOT, and reading it again there
# reads as (and is flagged as) a value that might have been clobbered.
RELEASE_SH="${REPO_ROOT}/tools/release.sh"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ KEEP-VERSION TEST FAILED: %s\n' "$*" >&2; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-keep-version-XXXXXX")"
cleanup() { rm -rf "${W}"; }
trap cleanup EXIT INT TERM

# ---- (1) extract the two functions under test into one sourceable file ------
extract_funcs() {
    local out="$1"; shift
    python3 - "${REPO_ROOT}/tools/release.sh" "${out}" "$@" <<'PYEOF'
import sys

src_path, out_path = sys.argv[1], sys.argv[2]
wanted = sys.argv[3:]
lines = open(src_path).readlines()

result = []
for name in wanted:
    head = name + "() {"
    in_func = False
    depth = 0
    captured = []
    for line in lines:
        if not in_func:
            if line.startswith(head):
                in_func = True
                depth = 0
            else:
                continue
        captured.append(line)
        depth += line.count('{') - line.count('}')
        if depth <= 0 and len(captured) > 2:
            break  # closing brace of this function reached
    if not captured:
        sys.exit("extract: %s not found in %s" % (name, src_path))
    result.extend(captured)
    result.append("\n")

open(out_path, 'w').writelines(result)
PYEOF
}

HELPER="${W}/keep_version_funcs.sh"
# version_sh: resolve_comp_stamp's own tools/version.sh call sites now go
# through this wrapper (threads --channel "${CHANNEL}" through), so it has to
# be extracted alongside resolve_comp_stamp or every version.sh call inside it
# fails with "command not found" the moment this harness sources it in
# isolation.
extract_funcs "${HELPER}" assert_stamp_untagged version_sh resolve_comp_stamp
grep -q '^assert_stamp_untagged() {' "${HELPER}" \
    || die "extraction failed — assert_stamp_untagged() not found in ${HELPER}"
grep -q '^version_sh() {' "${HELPER}" \
    || die "extraction failed — version_sh() not found in ${HELPER}"
grep -q '^resolve_comp_stamp() {' "${HELPER}" \
    || die "extraction failed — resolve_comp_stamp() not found in ${HELPER}"
grep -q 'KEEP_VERSION' "${HELPER}" \
    || die "extraction failed — resolve_comp_stamp() has no KEEP_VERSION branch"

# ---- (2) fake component source worktree (isolated) -------------------------
FAKE_SRC="${W}/comp-src"
mkdir -p "${FAKE_SRC}"
git -C "${FAKE_SRC}" init -q
git -C "${FAKE_SRC}" config user.email test@example.com
git -C "${FAKE_SRC}" config user.name test
printf 'package main\n' > "${FAKE_SRC}/main.go"
git -C "${FAKE_SRC}" add main.go
git -C "${FAKE_SRC}" commit -q -m "initial"
COMP_SHA="$(git -C "${FAKE_SRC}" rev-parse --short=8 HEAD)"

# ---- (3) fake REPO_ROOT (isolated git repo — needs a commit so `git tag`
#          works, and so `git add` has an index) ------------------------------
FAKE_REPO_ROOT="${W}/repo-root"
mkdir -p "${FAKE_REPO_ROOT}/tools" "${FAKE_REPO_ROOT}/versions"
git -C "${FAKE_REPO_ROOT}" init -q
git -C "${FAKE_REPO_ROOT}" config user.email test@example.com
git -C "${FAKE_REPO_ROOT}" config user.name test
cp "${REPO_ROOT}/tools/version.sh" "${FAKE_REPO_ROOT}/tools/version.sh"
printf '9.9.9\n' > "${FAKE_REPO_ROOT}/versions/cli"
git -C "${FAKE_REPO_ROOT}" add tools/version.sh versions/cli
git -C "${FAKE_REPO_ROOT}" commit -q -m "seed"

STAMP_FILE="${FAKE_REPO_ROOT}/versions/cli.stamp"
SEMVER_FILE="${FAKE_REPO_ROOT}/versions/cli"
TODAY="$(date -u +%Y.%m.%d)"

run_resolve() {
    # Clean subshell per case so `local` vars, the sourced functions and the
    # DRY_RUN/BUMP_KIND/FORCE_BUMP/KEEP_VERSION/REPO_ROOT env never leak
    # between cases. Args: <dry_run> <bump_kind> <force_bump> <keep_version>
    (
        set -euo pipefail
        # These five are the extracted function's entire input surface — it
        # reads them as globals. Shadowing REPO_ROOT inside this subshell is the
        # isolation mechanism, not an accident (SC2030), and the four flag
        # variables are consumed by the sourced code, not by this file (SC2034).
        # shellcheck disable=SC2030,SC2034
        REPO_ROOT="${FAKE_REPO_ROOT}"
        # shellcheck disable=SC2034
        DRY_RUN="${1:-0}"
        # shellcheck disable=SC2034
        BUMP_KIND="${2:-patch}"
        # shellcheck disable=SC2034
        FORCE_BUMP="${3:-0}"
        # shellcheck disable=SC2034
        KEEP_VERSION="${4:-0}"
        export BURROWEE_RELEASE_YES=1
        # shellcheck source=/dev/null
        source "${HELPER}"
        resolve_comp_stamp cli "${FAKE_SRC}"
    )
}

reset_fixture() {
    printf '9.9.9\n' > "${SEMVER_FILE}"
    git -C "${FAKE_REPO_ROOT}" reset -q
    git -C "${FAKE_REPO_ROOT}" tag -l | while IFS= read -r t; do
        [ -n "${t}" ] && git -C "${FAKE_REPO_ROOT}" tag -d "${t}" >/dev/null
    done
    return 0
}

# ---- (a) --keep-version + CHANGED source → version byte-identical, stamp new -
say "(a) --keep-version, changed source → versions/cli byte-identical, fresh stamp minted"
reset_fixture
printf 'v9.9.9.2020.01.01.deadbeef\n' > "${STAMP_FILE}"
semver_before="$(cat "${SEMVER_FILE}")"
got="$(run_resolve 0 patch 0 1)"
case "${got}" in
    v9.9.9."${TODAY}"."${COMP_SHA}") ;;
    *) die "(a) expected v9.9.9.${TODAY}.${COMP_SHA} (semver held, fresh date+sha), got '${got}'" ;;
esac
semver_after="$(cat "${SEMVER_FILE}")"
[ "${semver_before}" = "${semver_after}" ] \
    || die "(a) versions/cli changed: before='${semver_before}' after='${semver_after}' — --keep-version must leave it byte-identical"
on_disk_stamp="$(tr -d '[:space:]' < "${STAMP_FILE}")"
[ "${on_disk_stamp}" = "${got}" ] \
    || die "(a) fresh stamp not recorded in ${STAMP_FILE} (has '${on_disk_stamp}', want '${got}')"
echo "PASS (a): semver held at '${semver_after}', stamp moved to '${got}'"

# ---- (a2) staging contract: ONLY versions/cli.stamp is staged ---------------
# The caller's revert_version trap restores BOTH versions/<comp> and
# versions/<comp>.stamp. On this path only the stamp is ever written, so the
# stamp must be staged (so it rides the [RELEASED] marker and the trap can
# restore it) and versions/<comp> must NOT be — a staged version file here
# would ride the marker commit as a bump nobody asked for.
say "(a2) --keep-version stages versions/cli.stamp and NOT versions/cli"
staged="$(git -C "${FAKE_REPO_ROOT}" diff --cached --name-only | sort | tr '\n' ' ')"
[ "${staged}" = "versions/cli.stamp " ] \
    || die "(a2) expected exactly 'versions/cli.stamp' staged, got '${staged}'"
echo "PASS (a2): staged exactly '${staged}'"

# ---- (b) --keep-version + UNCHANGED source → still mints (bypasses reuse) ----
# Without --keep-version an unchanged source under the default patch bump is
# reused verbatim. --keep-version must override that: re-cutting a broken
# payload is exactly the case where the source did NOT move but a new stamp is
# needed anyway.
say "(b) --keep-version, UNCHANGED source → still mints a fresh stamp (reuse gate bypassed)"
reset_fixture
recorded="v9.9.9.2020.01.01.${COMP_SHA}"      # sha AND semver match → unchanged=1
printf '%s\n' "${recorded}" > "${STAMP_FILE}"
got="$(run_resolve 0 patch 0 1)"
[ "${got}" != "${recorded}" ] \
    || die "(b) --keep-version reused the recorded stamp '${recorded}' instead of minting a fresh one"
case "${got}" in
    v9.9.9."${TODAY}"."${COMP_SHA}") ;;
    *) die "(b) expected v9.9.9.${TODAY}.${COMP_SHA}, got '${got}'" ;;
esac
[ "$(cat "${SEMVER_FILE}")" = "9.9.9
" ] || [ "$(tr -d '[:space:]' < "${SEMVER_FILE}")" = "9.9.9" ] \
    || die "(b) versions/cli was bumped (got '$(tr -d '[:space:]' < "${SEMVER_FILE}")')"
echo "PASS (b): minted '${got}' over an unchanged source, semver still 9.9.9"

# ---- (c) collision: the resulting stamp already has a tag → refuse ----------
say "(c) --keep-version whose stamp already has a tag → refuse, write nothing"
reset_fixture
printf 'v9.9.9.2020.01.01.deadbeef\n' > "${STAMP_FILE}"
git -C "${FAKE_REPO_ROOT}" tag "cli/v9.9.9.${TODAY}.${COMP_SHA}"
stamp_before="$(tr -d '[:space:]' < "${STAMP_FILE}")"
set +e
err="$(run_resolve 0 patch 0 1 2>&1 >/dev/null)"
rc=$?
set -e
[ "${rc}" -ne 0 ] || die "(c) collision must exit non-zero, got rc=${rc}"
case "${err}" in
    *"cli/v9.9.9.${TODAY}.${COMP_SHA}"*) ;;
    *) die "(c) refusal must name the colliding tag; stderr was: ${err}" ;;
esac
case "${err}" in
    *"already exists"*) ;;
    *) die "(c) refusal must say the tag already exists; stderr was: ${err}" ;;
esac
case "${err}" in
    *"drop --keep-version"*) ;;
    *) die "(c) refusal must name a way forward (drop --keep-version); stderr was: ${err}" ;;
esac
stamp_after="$(tr -d '[:space:]' < "${STAMP_FILE}")"
[ "${stamp_before}" = "${stamp_after}" ] \
    || die "(c) a refused cut must not rewrite ${STAMP_FILE} (before='${stamp_before}' after='${stamp_after}')"
staged="$(git -C "${FAKE_REPO_ROOT}" diff --cached --name-only)"
[ -z "${staged}" ] || die "(c) a refused cut must stage nothing (staged: '${staged}')"
echo "PASS (c): refused with rc=${rc}, named the tag, wrote and staged nothing"

# ---- (d) --keep-version + --dry-run → same stamp, zero writes ---------------
say "(d) --keep-version + --dry-run → prints the stamp a real run would mint, writes nothing"
reset_fixture
printf 'v9.9.9.2020.01.01.deadbeef\n' > "${STAMP_FILE}"
before_status="$(git -C "${FAKE_REPO_ROOT}" status --porcelain)"
before_stamp="$(tr -d '[:space:]' < "${STAMP_FILE}")"
got="$(run_resolve 1 patch 0 1)"
case "${got}" in
    v9.9.9."${TODAY}"."${COMP_SHA}") ;;
    *) die "(d) dry-run must print the same stamp a real --keep-version run mints, got '${got}'" ;;
esac
after_status="$(git -C "${FAKE_REPO_ROOT}" status --porcelain)"
[ "${before_status}" = "${after_status}" ] \
    || die "(d) dry-run changed git status (before='${before_status}' after='${after_status}')"
[ "$(tr -d '[:space:]' < "${STAMP_FILE}")" = "${before_stamp}" ] \
    || die "(d) dry-run rewrote ${STAMP_FILE}"
[ "$(tr -d '[:space:]' < "${SEMVER_FILE}")" = "9.9.9" ] \
    || die "(d) dry-run must never touch versions/cli"
echo "PASS (d): dry-run printed '${got}' and wrote nothing"

# ---- (e) REGRESSION: without the flag, a normal cut still bumps -------------
# The guard against --keep-version becoming the accidental default. Same
# fixture as (a) — changed source, default patch — with KEEP_VERSION=0.
say "(e) regression: KEEP_VERSION=0, changed source, default patch → still bumps as before"
reset_fixture
printf 'v9.9.9.2020.01.01.deadbeef\n' > "${STAMP_FILE}"
got="$(run_resolve 0 patch 0 0)"
case "${got}" in
    v9.9.10."${TODAY}".*) ;;
    *) die "(e) a normal cut must still bump to v9.9.10, got '${got}' — --keep-version has leaked into the default path" ;;
esac
[ "$(tr -d '[:space:]' < "${SEMVER_FILE}")" = "9.9.10" ] \
    || die "(e) versions/cli not bumped to 9.9.10 (got '$(tr -d '[:space:]' < "${SEMVER_FILE}")')"
echo "PASS (e): default path still bumped 9.9.9 → 9.9.10, minted '${got}'"

# ---- (f) mutual exclusion, through the REAL entry point --------------------
# Each case must exit 2 (usage error, not "ran and failed"), print to STDERR,
# name BOTH flags, and list what is valid instead — cli-help.md §2/§4.
run_cli() {
    # Prints "<rc>|<stdout bytes>|<stderr>" for one real release.sh invocation.
    local out err rc
    out="${W}/cli.out"; err="${W}/cli.err"
    set +e
    bash "${RELEASE_SH}" "$@" </dev/null >"${out}" 2>"${err}"
    rc=$?
    set -e
    printf '%s|%s|%s' "${rc}" "$(wc -c <"${out}" | tr -d ' ')" "$(cat "${err}")"
}

assert_refusal() {
    local label="$1" other="$2"; shift 2
    local res rc outbytes errtext
    res="$(run_cli "$@")"
    rc="${res%%|*}"; res="${res#*|}"
    outbytes="${res%%|*}"; errtext="${res#*|}"
    [ "${rc}" = 2 ] || die "${label}: expected exit 2 (usage error), got ${rc}"
    [ "${outbytes}" = 0 ] || die "${label}: refusal must go to stderr, but ${outbytes} bytes went to stdout"
    case "${errtext}" in *"--keep-version"*) ;; *) die "${label}: refusal must name --keep-version; got: ${errtext}" ;; esac
    case "${errtext}" in *"${other}"*) ;; *) die "${label}: refusal must name ${other}; got: ${errtext}" ;; esac
    case "${errtext}" in *"Pick one of"*) ;; *) die "${label}: refusal must list what IS valid; got: ${errtext}" ;; esac
    echo "PASS ${label}: exit 2 on stderr, named --keep-version + ${other}, listed the valid alternatives"
}

say "(f) --keep-version refuses to combine with the flags that move the version"
assert_refusal "(f-1)" "--force"       gateway --keep-version --force --dry-run
assert_refusal "(f-2)" "--bump-minor"  gateway --keep-version --bump-minor --dry-run
assert_refusal "(f-3)" "--bump-major"  gateway --keep-version --bump-major --dry-run
# Both at once: the message must name both, not just whichever was checked first.
assert_refusal "(f-4)" "--force"       gateway --keep-version --bump-major --force --dry-run
assert_refusal "(f-5)" "--bump-major"  gateway --keep-version --bump-major --force --dry-run
# --distribute-only never touches versions/<comp>, so --keep-version there is a
# silent no-op unless it is refused (cli-help.md §6).
assert_refusal "(f-6)" "--distribute-only" \
    --distribute-only gateway v0.0.0.2020.01.01.deadbeef --keep-version --dry-run

# ---- (g) --keep-version is documented in the help output -------------------
# A flag missing from its own tool's help is undiscoverable (cli-help.md §5).
say "(g) --keep-version appears in release.sh --help (stdout, exit 0)"
set +e
help_out="$(bash "${RELEASE_SH}" --help </dev/null 2>/dev/null)"
help_rc=$?
set -e
[ "${help_rc}" = 0 ] || die "(g) --help must exit 0, got ${help_rc}"
case "${help_out}" in *"--keep-version"*) ;; *) die "(g) --help does not mention --keep-version" ;; esac
case "${help_out}" in *"REPUBLISH"*) ;; *) die "(g) --help must state that the semver is republished" ;; esac
echo "PASS (g): --help exits 0 on stdout and documents --keep-version as a republish"

echo
echo "✓ ALL KEEP-VERSION TESTS PASSED"
