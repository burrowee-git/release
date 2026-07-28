#!/usr/bin/env bash
# test-dispatcher-stamp-freeze.sh — prove resolve_disp_stamp() (release.sh)
# reuses the recorded versions/burrowee.stamp verbatim (date frozen) when the
# dispatcher source is unchanged, and mints + records a fresh stamp only when
# the recorded sha8 or semver segment no longer matches (or the file is
# missing/corrupt).
#
# release.sh is not designed to be sourced whole (it parses $1 and exits 2
# with no args, prompts interactively, etc. before ever reaching
# resolve_disp_stamp's definition). Mirrors tools/test-register-staged.sh's
# extract_register_staged pattern: pull the function's source text out of
# release.sh by line-anchored, brace-depth extraction into a sourceable file,
# then source THAT against a fully isolated fake REPO_ROOT + fake dispatcher
# source worktree — never the real Burrowee/burrowee checkout, never this
# repo's own versions/burrowee.stamp.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ DISPATCHER-STAMP-FREEZE TEST FAILED: %s\n' "$*" >&2; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-dispatcher-stamp-freeze-XXXXXX")"
cleanup() { rm -rf "${W}"; }
trap cleanup EXIT INT TERM

# ---- (1) extract resolve_disp_stamp() (+ its DISP_STAMP_FILE var) from
#          release.sh into a sourceable file, by text -----------------------
extract_resolve_disp_stamp() {
    local out="$1"
    python3 - "${REPO_ROOT}/tools/release.sh" "${out}" <<'PYEOF'
import sys

src_path, out_path = sys.argv[1], sys.argv[2]
lines = open(src_path).readlines()

start_marker = 'DISP_STAMP_FILE="${REPO_ROOT}/versions/burrowee.stamp"\n'
in_block = False
in_func = False
depth = 0
result = []

for line in lines:
    if not in_block:
        if line == start_marker:
            in_block = True
        else:
            continue

    result.append(line)

    if line.startswith('resolve_disp_stamp()'):
        in_func = True
        depth = 0

    if in_func:
        depth += line.count('{') - line.count('}')
        if depth <= 0 and len(result) > 2:
            break  # closing brace of resolve_disp_stamp reached

open(out_path, 'w').writelines(result)
PYEOF
}

# ---- (1b) same trick for revert_dispatcher_version() — the abort-recovery
#           trap handler that must also cover versions/burrowee.stamp now ---
extract_revert_dispatcher_version() {
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
        if line.startswith('revert_dispatcher_version()'):
            in_func = True
            depth = 0
        else:
            continue

    result.append(line)
    depth += line.count('{') - line.count('}')
    if depth <= 0 and len(result) > 2:
        break  # closing brace of revert_dispatcher_version reached

open(out_path, 'w').writelines(result)
PYEOF
}

HELPER="${W}/resolve_disp_stamp.sh"
extract_resolve_disp_stamp "${HELPER}"
grep -q '^resolve_disp_stamp() {' "${HELPER}" \
    || die "extraction failed — resolve_disp_stamp() not found in ${HELPER}"
grep -q '^}$' "${HELPER}" \
    || die "extraction failed — no closing brace captured in ${HELPER}"

REVERT_HELPER="${W}/revert_dispatcher_version.sh"
extract_revert_dispatcher_version "${REVERT_HELPER}"
grep -q '^revert_dispatcher_version() {' "${REVERT_HELPER}" \
    || die "extraction failed — revert_dispatcher_version() not found in ${REVERT_HELPER}"
grep -q 'versions/burrowee\.stamp' "${REVERT_HELPER}" \
    || die "extraction failed — revert_dispatcher_version() no longer reverts versions/burrowee.stamp"

# ---- (2) fake dispatcher source worktree (isolated — never the real
#          Burrowee/burrowee checkout) --------------------------------------
FAKE_DISPATCHER="${W}/dispatcher-src"
mkdir -p "${FAKE_DISPATCHER}"
git -C "${FAKE_DISPATCHER}" init -q
git -C "${FAKE_DISPATCHER}" config user.email test@example.com
git -C "${FAKE_DISPATCHER}" config user.name test
printf 'package main\n' > "${FAKE_DISPATCHER}/main.go"
git -C "${FAKE_DISPATCHER}" add main.go
git -C "${FAKE_DISPATCHER}" commit -q -m "initial"
DISPATCHER_SHA="$(git -C "${FAKE_DISPATCHER}" rev-parse --short=8 HEAD)"

# ---- (3) fake REPO_ROOT (isolated git repo — git add needs a real repo;
#          never this repo's own versions/burrowee.stamp) -------------------
FAKE_REPO_ROOT="${W}/repo-root"
mkdir -p "${FAKE_REPO_ROOT}/tools" "${FAKE_REPO_ROOT}/versions"
git -C "${FAKE_REPO_ROOT}" init -q
git -C "${FAKE_REPO_ROOT}" config user.email test@example.com
git -C "${FAKE_REPO_ROOT}" config user.name test
cp "${REPO_ROOT}/tools/version.sh" "${FAKE_REPO_ROOT}/tools/version.sh"
printf '9.9.9\n' > "${FAKE_REPO_ROOT}/versions/burrowee"
git -C "${FAKE_REPO_ROOT}" add tools/version.sh versions/burrowee
git -C "${FAKE_REPO_ROOT}" commit -q -m "seed"

STAMP_FILE="${FAKE_REPO_ROOT}/versions/burrowee.stamp"

run_resolve() {
    # Runs resolve_disp_stamp in a clean subshell so its `local` vars, the
    # sourced function, and DRY_RUN/REPO_ROOT/SRC_DISPATCHER env never leak
    # between cases.
    (
        set -euo pipefail
        REPO_ROOT="${FAKE_REPO_ROOT}"
        SRC_DISPATCHER="${FAKE_DISPATCHER}"
        DRY_RUN="${1:-0}"
        # shellcheck source=/dev/null
        source "${HELPER}"
        resolve_disp_stamp
    )
}

# ---- (a) recorded stamp matches current sha8 + semver → reuse verbatim ----
say "(a) unchanged dispatcher source → reuse recorded stamp (date frozen)"
recorded_stamp="v9.9.9.2020.01.01.${DISPATCHER_SHA}"
printf '%s\n' "${recorded_stamp}" > "${STAMP_FILE}"
got="$(run_resolve 0)"
[ "${got}" = "${recorded_stamp}" ] \
    || die "(a) expected reused stamp '${recorded_stamp}', got '${got}'"
on_disk="$(tr -d '[:space:]' < "${STAMP_FILE}")"
[ "${on_disk}" = "${recorded_stamp}" ] \
    || die "(a) reuse path must not rewrite ${STAMP_FILE} (got '${on_disk}')"
echo "PASS (a): reused '${got}' — no fresh (today's) date minted"

# ---- (b) recorded sha8 differs → fresh stamp minted + recorded -----------
say "(b) different recorded sha8 → mint fresh stamp + rewrite the record"
stale_stamp="v9.9.9.2020.01.01.deadbeef"
printf '%s\n' "${stale_stamp}" > "${STAMP_FILE}"
got="$(run_resolve 0)"
today="$(date -u +%Y.%m.%d)"
case "${got}" in
    v9.9.9."${today}".*) ;;
    *) die "(b) expected a fresh stamp dated ${today}, got '${got}'" ;;
esac
[ "${got}" != "${stale_stamp}" ] || die "(b) stale stamp was reused, not refreshed"
on_disk="$(tr -d '[:space:]' < "${STAMP_FILE}")"
[ "${on_disk}" = "${got}" ] \
    || die "(b) fresh stamp not written back to ${STAMP_FILE} (file has '${on_disk}', want '${got}')"
echo "PASS (b): minted fresh '${got}' and rewrote the record"

# ---- (c) recorded file missing → fresh stamp minted + recorded -----------
say "(c) missing versions/burrowee.stamp → mint fresh stamp + write it"
rm -f "${STAMP_FILE}"
got="$(run_resolve 0)"
case "${got}" in
    v9.9.9."${today}".*) ;;
    *) die "(c) expected a fresh stamp dated ${today}, got '${got}'" ;;
esac
[ -f "${STAMP_FILE}" ] || die "(c) resolve_disp_stamp did not create ${STAMP_FILE}"
on_disk="$(tr -d '[:space:]' < "${STAMP_FILE}")"
[ "${on_disk}" = "${got}" ] || die "(c) written stamp '${on_disk}' != returned stamp '${got}'"
echo "PASS (c): missing record → minted '${got}' and created the file"

# ---- (d) --dry-run must NEVER write versions/burrowee.stamp or git-add it -
say "(d) --dry-run: mismatch must not dirty the tree"
rm -f "${STAMP_FILE}"
before_status="$(git -C "${FAKE_REPO_ROOT}" status --porcelain)"
got="$(run_resolve 1)"
case "${got}" in
    v9.9.9."${today}".*) ;;
    *) die "(d) expected a fresh stamp dated ${today}, got '${got}'" ;;
esac
[ ! -f "${STAMP_FILE}" ] \
    || die "(d) --dry-run wrote ${STAMP_FILE} — must never dirty the tree"
after_status="$(git -C "${FAKE_REPO_ROOT}" status --porcelain)"
[ "${before_status}" = "${after_status}" ] \
    || die "(d) --dry-run changed git status (before='${before_status}' after='${after_status}')"
echo "PASS (d): dry-run computed '${got}' but wrote nothing and staged nothing"

# ---- (e) recorded semver differs (sha8 matches) → fresh stamp minted ------
say "(e) recorded semver stale (sha8 matches current) → mint fresh stamp"
old_semver_stamp="v0.0.1.2020.01.01.${DISPATCHER_SHA}"
printf '%s\n' "${old_semver_stamp}" > "${STAMP_FILE}"
got="$(run_resolve 0)"
case "${got}" in
    v9.9.9."${today}".*) ;;
    *) die "(e) expected a fresh v9.9.9 stamp (registry semver bumped), got '${got}'" ;;
esac
echo "PASS (e): sha8 alone is not enough — semver mismatch also mints fresh"

# ---- (f) abort recovery: revert_dispatcher_version() must also revert a
#          staged-but-uncommitted versions/burrowee.stamp write, mirroring
#          how it already reverts versions/burrowee. Without this, a cut that
#          aborts between resolve_disp_stamp's `git add` and the [RELEASED]
#          marker commit leaves a never-released date staged for the next
#          unchanged-source cut to wrongly reuse. ------------------------
say "(f) abort recovery — revert_dispatcher_version() reverts a staged versions/burrowee.stamp write"
committed_stamp="v9.9.9.2020.01.01.${DISPATCHER_SHA}"
printf '%s\n' "${committed_stamp}" > "${STAMP_FILE}"
git -C "${FAKE_REPO_ROOT}" add versions/burrowee.stamp
git -C "${FAKE_REPO_ROOT}" commit -q -m "commit baseline stamp"

# Simulate what resolve_disp_stamp does when it mints a fresh stamp: overwrite
# the file and stage it, as if the cut then died before its [RELEASED] marker.
staged_stamp="v9.9.9.2026.01.01.deadbeef"
printf '%s\n' "${staged_stamp}" > "${STAMP_FILE}"
git -C "${FAKE_REPO_ROOT}" add versions/burrowee.stamp

(
    set -euo pipefail
    REPO_ROOT="${FAKE_REPO_ROOT}"
    # shellcheck source=/dev/null
    source "${REVERT_HELPER}"
    revert_dispatcher_version
)

on_disk="$(tr -d '[:space:]' < "${STAMP_FILE}")"
[ "${on_disk}" = "${committed_stamp}" ] \
    || die "(f) revert_dispatcher_version left '${on_disk}', want the committed '${committed_stamp}'"
staged_diff="$(git -C "${FAKE_REPO_ROOT}" diff --cached --name-only)"
case "${staged_diff}" in
    *"versions/burrowee.stamp"*) die "(f) versions/burrowee.stamp is still staged after revert" ;;
esac
echo "PASS (f): aborted-cut stamp write reverted to the committed value, unstaged"

echo
echo "✓ ALL DISPATCHER-STAMP-FREEZE TESTS PASSED"
