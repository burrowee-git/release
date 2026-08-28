#!/usr/bin/env bash
# test-comp-version-freeze.sh — prove resolve_comp_stamp() (release.sh)
# generalizes resolve_disp_stamp's dispatcher-only freeze to EVERY component:
# reuse the recorded versions/<comp>.stamp verbatim (no bump, date frozen)
# when the component source is unchanged AND the default patch bump is in
# effect, else bump versions/<comp> per BUMP_KIND and mint + record a fresh
# stamp. --force (FORCE_BUMP=1) forces a bump even when unchanged. --dry-run
# never bumps or writes.
#
# release.sh is not designed to be sourced whole (see
# test-dispatcher-stamp-freeze.sh's header for why). Mirrors that file's
# extraction pattern: pull resolve_comp_stamp()'s source text out of
# release.sh by line-anchored, brace-depth extraction into a sourceable file,
# then source THAT against a fully isolated fake REPO_ROOT + fake component
# source worktree — never the real Burrowee/<comp> checkout, never this
# repo's own versions/<comp>.stamp.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ COMP-VERSION-FREEZE TEST FAILED: %s\n' "$*" >&2; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-comp-version-freeze-XXXXXX")"
cleanup() { rm -rf "${W}"; }
trap cleanup EXIT INT TERM

# ---- (1) extract resolve_comp_stamp() (+ version_sh(), its tools/version.sh
#          wrapper) from release.sh into a sourceable file, by text ----------
# version_sh threads --channel "${CHANNEL}" through every tools/version.sh
# call resolve_comp_stamp makes; without it every one of those calls fails
# "command not found" the moment this harness sources resolve_comp_stamp in
# isolation.
extract_resolve_comp_stamp() {
    local out="$1"
    python3 - "${REPO_ROOT}/tools/release.sh" "${out}" <<'PYEOF'
import sys

src_path, out_path = sys.argv[1], sys.argv[2]
lines = open(src_path).readlines()

wanted = ("version_sh()", "resolve_comp_stamp()")
result = []
for name in wanted:
    in_func = False
    depth = 0
    captured = []
    for line in lines:
        if not in_func:
            if line.startswith(name):
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

HELPER="${W}/resolve_comp_stamp.sh"
extract_resolve_comp_stamp "${HELPER}"
grep -q '^version_sh() {' "${HELPER}" \
    || die "extraction failed — version_sh() not found in ${HELPER}"
grep -q '^resolve_comp_stamp() {' "${HELPER}" \
    || die "extraction failed — resolve_comp_stamp() not found in ${HELPER}"
grep -q '^}$' "${HELPER}" \
    || die "extraction failed — no closing brace captured in ${HELPER}"

# ---- (2) fake component source worktree (isolated — never a real
#          Burrowee/<comp> checkout) -----------------------------------------
FAKE_SRC="${W}/comp-src"
mkdir -p "${FAKE_SRC}"
git -C "${FAKE_SRC}" init -q
git -C "${FAKE_SRC}" config user.email test@example.com
git -C "${FAKE_SRC}" config user.name test
printf 'package main\n' > "${FAKE_SRC}/main.go"
git -C "${FAKE_SRC}" add main.go
git -C "${FAKE_SRC}" commit -q -m "initial"
COMP_SHA="$(git -C "${FAKE_SRC}" rev-parse --short=8 HEAD)"

# ---- (3) fake REPO_ROOT (isolated git repo — git add needs a real repo;
#          never this repo's own versions/<comp>.stamp) ---------------------
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

run_resolve() {
    # Runs resolve_comp_stamp in a clean subshell so its `local` vars, the
    # sourced function, and DRY_RUN/BUMP_KIND/FORCE_BUMP/REPO_ROOT env never
    # leak between cases. Args: <dry_run> <bump_kind> <force_bump>
    (
        set -euo pipefail
        REPO_ROOT="${FAKE_REPO_ROOT}"
        DRY_RUN="${1:-0}"
        BUMP_KIND="${2:-patch}"
        FORCE_BUMP="${3:-0}"
        # version.sh's minor/major bump prompts for confirmation unless this is
        # set (or a TTY) — this harness is never interactive. Exported: version.sh
        # runs as a child process, so a plain (non-exported) assignment here
        # would never reach it.
        export BURROWEE_RELEASE_YES=1
        # shellcheck source=/dev/null
        source "${HELPER}"
        resolve_comp_stamp cli "${FAKE_SRC}"
    )
}

reset_semver() { printf '9.9.9\n' > "${SEMVER_FILE}"; }

# ---- (a) unchanged sha + patch default → reuse recorded, NO bump ----------
say "(a) unchanged sha + BUMP_KIND=patch (default) → reuse recorded, no bump"
reset_semver
recorded_stamp="v9.9.9.2020.01.01.${COMP_SHA}"
printf '%s\n' "${recorded_stamp}" > "${STAMP_FILE}"
got="$(run_resolve 0 patch 0)"
[ "${got}" = "${recorded_stamp}" ] \
    || die "(a) expected reused stamp '${recorded_stamp}', got '${got}'"
on_disk_stamp="$(tr -d '[:space:]' < "${STAMP_FILE}")"
[ "${on_disk_stamp}" = "${recorded_stamp}" ] \
    || die "(a) reuse path must not rewrite ${STAMP_FILE} (got '${on_disk_stamp}')"
on_disk_semver="$(tr -d '[:space:]' < "${SEMVER_FILE}")"
[ "${on_disk_semver}" = "9.9.9" ] \
    || die "(a) reuse path must not bump versions/cli (got '${on_disk_semver}')"
echo "PASS (a): reused '${got}' — no bump, no fresh date minted"

# ---- (b) changed sha → fresh stamp minted + rewritten + comp bumped ------
say "(b) changed sha → mint fresh stamp, rewrite record, bump versions/cli"
reset_semver
stale_stamp="v9.9.9.2020.01.01.deadbeef"
printf '%s\n' "${stale_stamp}" > "${STAMP_FILE}"
got="$(run_resolve 0 patch 0)"
today="$(date -u +%Y.%m.%d)"
case "${got}" in
    v9.9.10."${today}".*) ;;
    *) die "(b) expected a fresh v9.9.10 stamp dated ${today}, got '${got}'" ;;
esac
on_disk_stamp="$(tr -d '[:space:]' < "${STAMP_FILE}")"
[ "${on_disk_stamp}" = "${got}" ] \
    || die "(b) fresh stamp not written back to ${STAMP_FILE} (file has '${on_disk_stamp}', want '${got}')"
on_disk_semver="$(tr -d '[:space:]' < "${SEMVER_FILE}")"
[ "${on_disk_semver}" = "9.9.10" ] \
    || die "(b) versions/cli not bumped to patch+1 (got '${on_disk_semver}')"
staged_diff="$(git -C "${FAKE_REPO_ROOT}" diff --cached --name-only)"
case "${staged_diff}" in
    *"versions/cli.stamp"*) ;;
    *) die "(b) versions/cli.stamp was not git-added (staged: '${staged_diff}')" ;;
esac
echo "PASS (b): minted fresh '${got}', rewrote the record, bumped versions/cli to 9.9.10"

# ---- (c) --force/FORCE_BUMP=1 on unchanged sha → bumps anyway -------------
say "(c) unchanged sha but FORCE_BUMP=1 → bumps anyway"
reset_semver
recorded_stamp="v9.9.9.2020.01.01.${COMP_SHA}"
printf '%s\n' "${recorded_stamp}" > "${STAMP_FILE}"
got="$(run_resolve 0 patch 1)"
case "${got}" in
    v9.9.10."${today}".*) ;;
    *) die "(c) expected a fresh v9.9.10 stamp under --force, got '${got}'" ;;
esac
[ "${got}" != "${recorded_stamp}" ] || die "(c) --force did not override the unchanged-sha reuse"
on_disk_semver="$(tr -d '[:space:]' < "${SEMVER_FILE}")"
[ "${on_disk_semver}" = "9.9.10" ] \
    || die "(c) --force must still bump versions/cli (got '${on_disk_semver}')"
echo "PASS (c): --force bumped an otherwise-unchanged component to '${got}'"

# ---- (c2) BUMP_KIND=minor on an UNCHANGED component → bumps anyway --------
# The reuse gate is patch-only (BUMP_KIND=patch AND not forced); an explicit
# --bump-minor/--bump-major must still bump even when the sha/semver match
# the record, same as --force.
say "(c2) unchanged sha but BUMP_KIND=minor → bumps anyway (reuse gate is patch-only)"
reset_semver
recorded_stamp="v9.9.9.2020.01.01.${COMP_SHA}"
printf '%s\n' "${recorded_stamp}" > "${STAMP_FILE}"
got="$(run_resolve 0 minor 0)"
case "${got}" in
    v9.10.0."${today}".*) ;;
    *) die "(c2) expected a fresh v9.10.0 stamp under BUMP_KIND=minor, got '${got}'" ;;
esac
[ "${got}" != "${recorded_stamp}" ] || die "(c2) BUMP_KIND=minor did not override the unchanged-sha reuse"
on_disk_semver="$(tr -d '[:space:]' < "${SEMVER_FILE}")"
[ "${on_disk_semver}" = "9.10.0" ] \
    || die "(c2) BUMP_KIND=minor must still bump versions/cli (got '${on_disk_semver}')"
on_disk_stamp="$(tr -d '[:space:]' < "${STAMP_FILE}")"
[ "${on_disk_stamp}" = "${got}" ] \
    || die "(c2) fresh minor stamp not written back to ${STAMP_FILE} (file has '${on_disk_stamp}', want '${got}')"
echo "PASS (c2): BUMP_KIND=minor bumped an otherwise-unchanged component to '${got}'"

# ---- (d) --dry-run: never bumps/writes; correct echo either way ----------
say "(d) --dry-run unchanged → echoes recorded, no bump, no write"
reset_semver
recorded_stamp="v9.9.9.2020.01.01.${COMP_SHA}"
printf '%s\n' "${recorded_stamp}" > "${STAMP_FILE}"
before_status="$(git -C "${FAKE_REPO_ROOT}" status --porcelain)"
got="$(run_resolve 1 patch 0)"
[ "${got}" = "${recorded_stamp}" ] || die "(d) expected reused stamp under dry-run, got '${got}'"
after_status="$(git -C "${FAKE_REPO_ROOT}" status --porcelain)"
[ "${before_status}" = "${after_status}" ] \
    || die "(d) dry-run changed git status (before='${before_status}' after='${after_status}')"
on_disk_semver="$(tr -d '[:space:]' < "${SEMVER_FILE}")"
[ "${on_disk_semver}" = "9.9.9" ] || die "(d) dry-run must never bump versions/cli"
echo "PASS (d-1): dry-run unchanged reused '${got}', wrote nothing, bumped nothing"

say "(d) --dry-run changed sha → echoes a fresh stamp over the CURRENT (unbumped) semver"
reset_semver
stale_stamp="v9.9.9.2020.01.01.deadbeef"
printf '%s\n' "${stale_stamp}" > "${STAMP_FILE}"
before_status="$(git -C "${FAKE_REPO_ROOT}" status --porcelain)"
got="$(run_resolve 1 patch 0)"
case "${got}" in
    v9.9.9."${today}".*) ;;
    *) die "(d-2) expected a fresh v9.9.9 (unbumped) stamp dated ${today}, got '${got}'" ;;
esac
after_status="$(git -C "${FAKE_REPO_ROOT}" status --porcelain)"
[ "${before_status}" = "${after_status}" ] \
    || die "(d-2) dry-run changed git status (before='${before_status}' after='${after_status}')"
on_disk_semver="$(tr -d '[:space:]' < "${SEMVER_FILE}")"
[ "${on_disk_semver}" = "9.9.9" ] || die "(d-2) dry-run must never bump versions/cli"
[ ! -f "${STAMP_FILE}" ] || {
    on_disk_stamp="$(tr -d '[:space:]' < "${STAMP_FILE}")"
    [ "${on_disk_stamp}" = "${stale_stamp}" ] \
        || die "(d-2) dry-run must never rewrite ${STAMP_FILE} (got '${on_disk_stamp}')"
}
echo "PASS (d-2): dry-run changed-source reused unbumped semver, minted '${got}', wrote nothing"

# ---- (e) missing/corrupt record → treated as changed ----------------------
say "(e) missing versions/cli.stamp → treated as changed → fresh stamp + write"
reset_semver
rm -f "${STAMP_FILE}"
got="$(run_resolve 0 patch 0)"
case "${got}" in
    v9.9.10."${today}".*) ;;
    *) die "(e-1) expected a fresh v9.9.10 stamp, got '${got}'" ;;
esac
[ -f "${STAMP_FILE}" ] || die "(e-1) resolve_comp_stamp did not create ${STAMP_FILE}"
echo "PASS (e-1): missing record → minted '${got}' and created the file"

say "(e) corrupt versions/cli.stamp (garbage content) → treated as changed"
reset_semver
printf 'not-a-stamp\n' > "${STAMP_FILE}"
got="$(run_resolve 0 patch 0)"
case "${got}" in
    v9.9.10."${today}".*) ;;
    *) die "(e-2) expected a fresh v9.9.10 stamp for a corrupt record, got '${got}'" ;;
esac
echo "PASS (e-2): corrupt record → minted '${got}'"

# ---- (f) sha8 MATCHES the record but recorded semver DIFFERS → bump -------
# Exercises the rec_sv arm of the reuse gate explicitly: an unchanged sha
# alone is not enough to reuse — the recorded semver segment must ALSO match
# versions/cli, else it's treated as changed (e.g. someone hand-edited
# versions/cli, or the recorded stamp predates a since-reverted bump).
say "(f) sha8 matches record but recorded semver differs → treated as changed → bump"
reset_semver
stale_semver_stamp="v1.2.3.2020.01.01.${COMP_SHA}"
printf '%s\n' "${stale_semver_stamp}" > "${STAMP_FILE}"
got="$(run_resolve 0 patch 0)"
case "${got}" in
    v9.9.10."${today}".*) ;;
    *) die "(f) expected a fresh v9.9.10 stamp (recorded semver 1.2.3 != current 9.9.9), got '${got}'" ;;
esac
[ "${got}" != "${stale_semver_stamp}" ] || die "(f) stale-semver record was reused, not treated as changed"
on_disk_semver="$(tr -d '[:space:]' < "${SEMVER_FILE}")"
[ "${on_disk_semver}" = "9.9.10" ] \
    || die "(f) versions/cli not bumped to patch+1 (got '${on_disk_semver}')"
on_disk_stamp="$(tr -d '[:space:]' < "${STAMP_FILE}")"
[ "${on_disk_stamp}" = "${got}" ] \
    || die "(f) fresh stamp not written back to ${STAMP_FILE} (file has '${on_disk_stamp}', want '${got}')"
echo "PASS (f): matching sha8 alone did not reuse — semver mismatch bumped + rewrote to '${got}'"

echo
echo "✓ ALL COMP-VERSION-FREEZE TESTS PASSED"
