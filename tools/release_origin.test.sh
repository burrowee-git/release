#!/usr/bin/env bash
# release_origin.test.sh — unit tests for tools/release_origin.sh.
#
# Exercises every predicate directly against throwaway repos under a temp dir.
# NO part of the release path runs: release.sh is never invoked, nothing is
# built, signed or published. "origin" is a local bare repo, so the fetch
# predicate is exercised for real without a network.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HERE}/release_origin.sh"

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
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig"   # keep the operator's identity/hooks out of it
/usr/bin/git config --file "${GIT_CONFIG_GLOBAL}" user.name  "Cut Origin Test"
/usr/bin/git config --file "${GIT_CONFIG_GLOBAL}" user.email "cut-origin@test.invalid"
/usr/bin/git config --file "${GIT_CONFIG_GLOBAL}" init.defaultBranch main

# new_origin_and_clone <name> — a bare "origin" plus a clone with one commit on
# main, pushed. Prints the clone path.
new_origin_and_clone() {
    local bare="${WORK}/$1.git" clone="${WORK}/$1"
    /usr/bin/git init --quiet --bare "${bare}"
    /usr/bin/git clone --quiet "${bare}" "${clone}" 2>/dev/null
    echo "seed" > "${clone}/README.md"
    /usr/bin/git -C "${clone}" add README.md
    /usr/bin/git -C "${clone}" commit --quiet -m "seed"
    /usr/bin/git -C "${clone}" push --quiet -u origin main
    printf '%s' "${clone}"
}

# ── check 1: registry source ─────────────────────────────────────────────────
is_registry_source /a/b /a/b && r=0 || r=1
check "registry: identical paths pass" "${r}" "0"
is_registry_source /a/b/.worktrees/dev /a/b && r=0 || r=1
check "registry: a different path fails" "${r}" "1"

# ── check 2: primary worktree ────────────────────────────────────────────────
MAIN="$(new_origin_and_clone primary)"
/usr/bin/git -C "${MAIN}" worktree add --quiet -b feature "${MAIN}/../primary-feature" >/dev/null 2>&1
is_primary_worktree "${MAIN}" && r=0 || r=1
check "primary: the clone itself passes" "${r}" "0"
is_primary_worktree "${MAIN}/../primary-feature" && r=0 || r=1
check "primary: a linked worktree fails" "${r}" "1"
is_primary_worktree "${WORK}" && r=0 || r=1
check "primary: a non-repo fails" "${r}" "1"

# ── check 3: branch ──────────────────────────────────────────────────────────
check "branch: reports main" "$(worktree_branch "${MAIN}")" "main"
check "branch: reports a feature branch" "$(worktree_branch "${MAIN}/../primary-feature")" "feature"
worktree_branch "${WORK}" >/dev/null; r=$?
check "branch: a non-repo returns 1, not git's 128" "${r}" "1"

# ── check 4: clean tree ──────────────────────────────────────────────────────
tree_clean "${MAIN}" && r=0 || r=1
check "clean: a clean tree passes" "${r}" "0"
echo "edit" >> "${MAIN}/README.md"
tree_clean "${MAIN}" && r=0 || r=1
check "clean: a modified file fails" "${r}" "1"
/usr/bin/git -C "${MAIN}" checkout --quiet -- README.md
touch "${MAIN}/stray.txt"
tree_clean "${MAIN}" && r=0 || r=1
check "clean: an untracked file also fails" "${r}" "1"
rm -f "${MAIN}/stray.txt"

# status.showUntrackedFiles=no is a per-repo config knob that must not be able
# to quietly retire the untracked half of this check — tree_clean passes
# --untracked-files=all specifically so this config cannot weaken it.
UNTRACKED_CFG="$(new_origin_and_clone untracked-config)"
/usr/bin/git -C "${UNTRACKED_CFG}" config --local status.showUntrackedFiles no
touch "${UNTRACKED_CFG}/stray.txt"
tree_clean "${UNTRACKED_CFG}" && r=0 || r=1
check "clean: an untracked file fails even under status.showUntrackedFiles=no" "${r}" "1"
rm -f "${UNTRACKED_CFG}/stray.txt"

# ── check 4b: clean tree, staged tolerance ───────────────────────────────────
# The one caller (release repo, --distribute-only) stages versions/<comp> and
# versions/<comp>.stamp so both ride the [RELEASED] marker commit. Positive
# case first, per the plan's falsifiability note — every negative case below
# is a variation on a fixture that is proven to pass unmodified.
#
# versions/edge is committed to HEAD FIRST (as an earlier release would have
# left it) and only then bumped+staged, so its status is real "M " —
# index-modified against an existing HEAD entry. versions/edge.stamp is
# newly created, so its status is real "A ". Both code letters the tolerance
# is supposed to accept are exercised, not just one.
TOL="$(new_origin_and_clone tolerance)"
mkdir -p "${TOL}/versions"
echo "1.0.0" > "${TOL}/versions/edge"
/usr/bin/git -C "${TOL}" add versions/edge
/usr/bin/git -C "${TOL}" commit --quiet -m "seed versions/edge"
echo "1.0.1" > "${TOL}/versions/edge"
echo "1.0.1" > "${TOL}/versions/edge.stamp"
/usr/bin/git -C "${TOL}" add versions/edge versions/edge.stamp
tree_clean_except_staged "${TOL}" "versions/edge" "versions/edge.stamp" && r=0 || r=1
check "clean-except-staged: an allowed 'M ' bump plus an allowed 'A ' stamp pass" "${r}" "0"

# What would have to change for the above to fail: the allow-list must be
# honoured. Confirm it actually distinguishes staged-and-listed from
# staged-and-not by calling with NO allowed paths against the same fixture.
tree_clean_except_staged "${TOL}" && r=0 || r=1
check "clean-except-staged: same fixture fails tree_clean_except_staged with no allow-list (mutation check)" "${r}" "1"

# No allowed paths at all ⇒ behaves exactly like tree_clean: a clean tree
# passes, any staged change fails.
CES_CLEAN="$(new_origin_and_clone ces-clean)"
tree_clean_except_staged "${CES_CLEAN}" && r=0 || r=1
check "clean-except-staged: a clean tree with no allow-list passes" "${r}" "0"

# A staged change outside the allow-list is refused — the allow-list is exact,
# additional staged files are not swept in for free.
echo "extra" > "${TOL}/README.md"
/usr/bin/git -C "${TOL}" add README.md
tree_clean_except_staged "${TOL}" "versions/edge" "versions/edge.stamp" && r=0 || r=1
check "clean-except-staged: an extra staged file outside the allow-list fails" "${r}" "1"
/usr/bin/git -C "${TOL}" reset --quiet -- README.md
/usr/bin/git -C "${TOL}" checkout --quiet -- README.md

# MM (staged AND further worktree-modified) is refused even for an allowed
# path: the stamp would have been computed from the worktree file while the
# marker commit records the index, which could disagree.
echo "more" >> "${TOL}/versions/edge"
tree_clean_except_staged "${TOL}" "versions/edge" "versions/edge.stamp" && r=0 || r=1
check "clean-except-staged: MM on an allowed path still fails" "${r}" "1"
/usr/bin/git -C "${TOL}" checkout --quiet -- versions/edge

# Untracked is refused regardless of the allow-list, exactly as tree_clean.
touch "${TOL}/versions/stray"
tree_clean_except_staged "${TOL}" "versions/edge" "versions/edge.stamp" && r=0 || r=1
check "clean-except-staged: an untracked file fails even with an allow-list" "${r}" "1"
rm -f "${TOL}/versions/stray"

# The comparison is exact-match, not a prefix or glob: a staged path that
# merely starts with an allowed one is still refused. This is the residual-1
# guard the plan calls out (a staged versions/burrowee bump is deliberately
# not tolerated).
echo "1.0.0" > "${TOL}/versions/edge-extra"
/usr/bin/git -C "${TOL}" add versions/edge-extra
tree_clean_except_staged "${TOL}" "versions/edge" "versions/edge.stamp" && r=0 || r=1
check "clean-except-staged: a staged path that is a prefix-match only fails" "${r}" "1"
/usr/bin/git -C "${TOL}" reset --quiet -- versions/edge-extra
rm -f "${TOL}/versions/edge-extra"

# Baseline still passes after all the above cleanup (fixture hygiene check).
tree_clean_except_staged "${TOL}" "versions/edge" "versions/edge.stamp" && r=0 || r=1
check "clean-except-staged: the fixture is restored to the passing baseline" "${r}" "0"

# ── check 4c: staged_tolerance_for ───────────────────────────────────────────
check "tolerance: full cut (distribute_only=0) yields nothing" "$(staged_tolerance_for 0 edge)" ""
staged_tolerance_for 0 edge >/dev/null && r=0 || r=1
check "tolerance: full cut returns 0" "${r}" "0"

check "tolerance: distribute-only with no comp yields nothing" "$(staged_tolerance_for 1 "")" ""

check "tolerance: distribute-only names exactly versions/<comp> and its stamp" \
    "$(staged_tolerance_for 1 edge)" "$(printf 'versions/edge\nversions/edge.stamp')"

# ── check 5: origin comparison ───────────────────────────────────────────────
SYNC="$(new_origin_and_clone sync)"
check "origin: an up-to-date clone is in-sync" "$(origin_sync_status "${SYNC}")" "in-sync"
origin_sync_status "${SYNC}" >/dev/null && r=0 || r=1
check "origin: in-sync returns 0" "${r}" "0"

# Behind: push a second commit through another clone, leave SYNC untouched.
OTHER="${WORK}/sync-other"
/usr/bin/git clone --quiet "${WORK}/sync.git" "${OTHER}" 2>/dev/null
echo "second" > "${OTHER}/second.txt"
/usr/bin/git -C "${OTHER}" add second.txt
/usr/bin/git -C "${OTHER}" commit --quiet -m "second"
/usr/bin/git -C "${OTHER}" push --quiet origin main
check "origin: one commit behind is reported with its distance" "$(origin_sync_status "${SYNC}")" "behind:1"
origin_sync_status "${SYNC}" >/dev/null && r=0 || r=1
check "origin: behind returns 1" "${r}" "1"

# Ahead: a local commit that was never pushed.
AHEAD="$(new_origin_and_clone ahead)"
echo "local" > "${AHEAD}/local.txt"
/usr/bin/git -C "${AHEAD}" add local.txt
/usr/bin/git -C "${AHEAD}" commit --quiet -m "local only"
check "origin: one commit ahead is reported" "$(origin_sync_status "${AHEAD}")" "ahead:1"

# Diverged: local commit here, different commit pushed there.
DIV="$(new_origin_and_clone diverged)"
DIVOTHER="${WORK}/diverged-other"
/usr/bin/git clone --quiet "${WORK}/diverged.git" "${DIVOTHER}" 2>/dev/null
echo "theirs" > "${DIVOTHER}/theirs.txt"
/usr/bin/git -C "${DIVOTHER}" add theirs.txt
/usr/bin/git -C "${DIVOTHER}" commit --quiet -m "theirs"
/usr/bin/git -C "${DIVOTHER}" push --quiet origin main
echo "mine" > "${DIV}/mine.txt"
/usr/bin/git -C "${DIV}" add mine.txt
/usr/bin/git -C "${DIV}" commit --quiet -m "mine"
check "origin: divergence reports both counts" "$(origin_sync_status "${DIV}")" "diverged:1:1"

# A remote with no fetch refspec still fetches on demand but no longer
# updates refs/remotes/origin/main, so the tracking ref goes stale while
# FETCH_HEAD stays fresh — the exact disagreement the FETCH_HEAD choice
# exists for. Comparing against the tracking ref here would report in-sync
# for a tree that is a commit behind.
STALE="$(new_origin_and_clone stale-ref)"
STALE_OTHER="${WORK}/stale-ref-other"
/usr/bin/git clone --quiet "${WORK}/stale-ref.git" "${STALE_OTHER}" 2>/dev/null
echo "newer" > "${STALE_OTHER}/newer.txt"
/usr/bin/git -C "${STALE_OTHER}" add newer.txt
/usr/bin/git -C "${STALE_OTHER}" commit --quiet -m "newer"
/usr/bin/git -C "${STALE_OTHER}" push --quiet origin main
/usr/bin/git -C "${STALE}" config --unset remote.origin.fetch
tracking_before="$(/usr/bin/git -C "${STALE}" rev-parse refs/remotes/origin/main)"
check "origin: a stale tracking ref does not mask a behind state" "$(origin_sync_status "${STALE}")" "behind:1"
tracking_after="$(/usr/bin/git -C "${STALE}" rev-parse refs/remotes/origin/main)"
check "origin: the tracking ref really was stale (the fetch could not move it)" "${tracking_after}" "${tracking_before}"

# Fetch failure: point the remote at a path that does not exist. A cut must
# never fall back to a stale remote ref, so this is its own status, not
# in-sync.
GONE="$(new_origin_and_clone gone)"
/usr/bin/git -C "${GONE}" remote set-url origin "${WORK}/no-such-repo.git"
check "origin: an unreachable remote is fetch-failed, not in-sync" "$(origin_sync_status "${GONE}")" "fetch-failed"
origin_sync_status "${GONE}" >/dev/null && r=0 || r=1
check "origin: fetch-failed returns 1" "${r}" "1"

# ── the composite ────────────────────────────────────────────────────────────
COMP="$(new_origin_and_clone composite)"
out="$(assert_release_origin edge "${COMP}" "${COMP}" strict 2>&1)" && r=0 || r=1
check "assert: the happy path passes" "${r}" "0"
check "assert: the happy path is silent" "${out}" ""

out="$(assert_release_origin edge "${COMP}" "/registry/edge/code/edge" strict 2>&1)" && r=0 || r=1
check "assert: a non-registry path is rejected" "${r}" "1"
check_contains "assert: rejection names the override mechanism" "${out}" "BURROWEE_SRC_"
check_contains "assert: rejection shows what was expected" "${out}" "/registry/edge/code/edge"

/usr/bin/git -C "${COMP}" worktree add --quiet -b wt "${WORK}/composite-wt" >/dev/null 2>&1
out="$(assert_release_origin edge "${WORK}/composite-wt" "${WORK}/composite-wt" strict 2>&1)" && r=0 || r=1
check "assert: a linked worktree is rejected" "${r}" "1"
check_contains "assert: worktree rejection says why" "${out}" "linked worktree"

BEHIND="$(new_origin_and_clone composite-behind)"
BOTHER="${WORK}/composite-behind-other"
/usr/bin/git clone --quiet "${WORK}/composite-behind.git" "${BOTHER}" 2>/dev/null
echo x > "${BOTHER}/x.txt"; /usr/bin/git -C "${BOTHER}" add x.txt
/usr/bin/git -C "${BOTHER}" commit --quiet -m x
/usr/bin/git -C "${BOTHER}" push --quiet origin main
out="$(assert_release_origin edge "${BEHIND}" "${BEHIND}" strict 2>&1)" && r=0 || r=1
check "assert: behind origin is rejected" "${r}" "1"
check_contains "assert: behind names the fix" "${out}" "git pull --ff-only"

# Ahead: a local commit that was never pushed, asserted THROUGH assert_release_origin
# directly (not via the staged-tolerance narrowing suite below, and not via
# origin_sync_status alone — check 5 above already covers that unit). Without
# this, "ahead" was checkable only inside case (e), which is really testing the
# tolerance not swallowing the sync check; a mutation that breaks assert_release_origin's
# own ahead handling with no tolerance in play at all would have nothing else to
# catch it at this composite level.
AHEAD_COMPOSITE="$(new_origin_and_clone composite-ahead)"
echo local > "${AHEAD_COMPOSITE}/local.txt"
/usr/bin/git -C "${AHEAD_COMPOSITE}" add local.txt
/usr/bin/git -C "${AHEAD_COMPOSITE}" commit --quiet -m "local only"
out="$(assert_release_origin edge "${AHEAD_COMPOSITE}" "${AHEAD_COMPOSITE}" strict 2>&1)" && r=0 || r=1
check "assert: ahead of origin is rejected" "${r}" "1"
check_contains "assert: ahead names the fix" "${out}" "merge it through a PR first"

# ── the distribute-only staged tolerance, driven through the strict path ────
# This cannot go through --dry-run: dry-run puts the guard in report mode,
# which returns 0 regardless of findings, so a test that only exercised
# --dry-run would stay green whether or not the tolerance wiring works at
# all. Every call below is mode=strict.
DIST="$(new_origin_and_clone distribute)"
mkdir -p "${DIST}/versions"
echo "1.0.1" > "${DIST}/versions/edge"
echo "1.0.1" > "${DIST}/versions/edge.stamp"
/usr/bin/git -C "${DIST}" add versions/edge versions/edge.stamp

# Positive case first: the release repo carrying exactly the two staged files
# rkit build produces, asserted with the tolerance staged_tolerance_for hands
# back for --distribute-only. This must pass before any negative case below
# is trusted to mean anything (assert_release_origin returns at its first failing
# arm, so a fixture that trips registry/worktree/branch would never reach the
# clean-tree check at all).
# mapfile/readarray is a bash-4+ builtin, not present in macOS's system bash
# 3.2 that this suite runs under — build the array with a read loop instead,
# matching tree_clean_except_staged's own idiom above. Skipping blank lines
# is what makes an all-empty tolerance (the full-cut case below) collapse to
# a truly zero-element array rather than one element holding "".
DIST_ALLOWED=()
while IFS= read -r line; do
    [ -n "${line}" ] || continue
    DIST_ALLOWED+=("${line}")
done <<EOF
$(staged_tolerance_for 1 edge)
EOF
out="$(assert_release_origin "release repo" "${DIST}" "${DIST}" strict "${DIST_ALLOWED[@]}" 2>&1)" && r=0 || r=1
check "assert: distribute-only staged bump passes under strict mode" "${r}" "0"
check "assert: distribute-only staged bump is silent" "${out}" ""

# Falsifiability: the identical fixture, asserted with NO allowed-staged
# arguments, must fail — this is the exact defect being fixed (a full-cut
# style call, or the pre-Task-3 assert_release_origin, refuses a staged bump).
# Seeing this fail confirms the positive case above is actually exercising
# the tolerance wiring and not passing for some unrelated reason.
out="$(assert_release_origin "release repo" "${DIST}" "${DIST}" strict 2>&1)" && r=0 || r=1
check "assert: the same staged bump fails with no tolerance argument (the pre-fix behavior)" "${r}" "1"
check_contains "assert: the no-tolerance failure is the dirty-tree message" "${out}" "source tree is dirty"

# A staged file the tolerance list does not name — a dispatcher bump, the
# residual-1 case the plan says must stay refused — is refused even though
# versions/edge and versions/edge.stamp are still correctly staged.
echo "9.9.9" > "${DIST}/versions/burrowee"
/usr/bin/git -C "${DIST}" add versions/burrowee
out="$(assert_release_origin "release repo" "${DIST}" "${DIST}" strict "${DIST_ALLOWED[@]}" 2>&1)" && r=0 || r=1
check "assert: an additional staged versions/burrowee is still refused" "${r}" "1"
check_contains "assert: refusal names the tolerated set" "${out}" "staged is tolerated for exactly"
/usr/bin/git -C "${DIST}" reset --quiet -- versions/burrowee
rm -f "${DIST}/versions/burrowee"

# Confirm the fixture is back to the passing baseline (hygiene, not a new
# assertion) — guards against a later edit leaving DIST dirty for whatever
# runs after it in this file.
out="$(assert_release_origin "release repo" "${DIST}" "${DIST}" strict "${DIST_ALLOWED[@]}" 2>&1)" && r=0 || r=1
check "assert: distribute-only fixture is restored to the passing baseline" "${r}" "0"

# A full cut (distribute_only=0) gets an empty tolerance list, so the SAME
# staged-bump fixture is refused under the full-cut call shape — the
# exemption is for --distribute-only only, never for a full cut.
FULLCUT_ALLOWED=()
while IFS= read -r line; do
    [ -n "${line}" ] || continue
    FULLCUT_ALLOWED+=("${line}")
done <<EOF
$(staged_tolerance_for 0 edge)
EOF
check "assert: staged_tolerance_for really yields zero elements for a full cut (fixture check)" "${#FULLCUT_ALLOWED[@]}" "0"
# ${FULLCUT_ALLOWED[@]+"${FULLCUT_ALLOWED[@]}"}, not a bare expansion: this
# array is genuinely empty, and bare "${arr[@]}" on a zero-element array is
# an unbound-variable error under set -u in bash 3.2 (the shell this suite
# runs under) — the same portability trap production code guards against.
out="$(assert_release_origin "release repo" "${DIST}" "${DIST}" strict ${FULLCUT_ALLOWED[@]+"${FULLCUT_ALLOWED[@]}"} 2>&1)" && r=0 || r=1
check "assert: the same staged bump is refused under a full-cut tolerance (empty list)" "${r}" "1"

# report mode: same findings, never fatal — a dry run publishes nothing.
out="$(assert_release_origin edge "${BEHIND}" "/elsewhere" report 2>&1)" && r=0 || r=1
check "assert: report mode returns 0" "${r}" "0"
check_contains "assert: report mode still says what is wrong" "${out}" "⚠"

# ── the guard's own coverage: four narrowing dimensions, cases (a)-(h) ──────
# The tolerance admits EXACTLY versions/<comp> and versions/<comp>.stamp (b),
# STAGED ONLY — never worktree-modified-on-top (c) or untracked (d) — and only
# because release.sh forwards it for --distribute-only; every other call site
# passes no trailing paths at all, so the SAME fixture with none supplied (f)
# must refuse exactly like the pre-tolerance guard did. staged_tolerance_for
# itself gates that last dimension (g)/(h): nothing for a full cut, exactly
# the two paths for --distribute-only.
#
# Case (a) is the GATE, per assert_release_origin's own short-circuit: it returns
# at its FIRST failing arm, and the clean-tree check (where the tolerance
# lives) is the fourth. A fixture that trips is_registry_source,
# is_primary_worktree, or the on-main check would never reach the tolerance
# at all — every case below would "pass" for a reason that has nothing to do
# with the tolerance. (a) passing first is what makes (b)-(f) mean anything.
#
# A fresh fixture, not the DIST one above (same shape, own component name)
# so this section stands as independent, permanent evidence rather than
# reusing another task's harness.
CLI="$(new_origin_and_clone task5-cli)"
mkdir -p "${CLI}/versions"
echo "1.0.0" > "${CLI}/versions/cli"
/usr/bin/git -C "${CLI}" add versions/cli
/usr/bin/git -C "${CLI}" commit --quiet -m "seed versions/cli"
/usr/bin/git -C "${CLI}" push --quiet origin main

# (a) — versions/cli bumped (M, against the just-committed HEAD entry) and
# versions/cli.stamp created fresh (A), both staged, worktree otherwise clean,
# HEAD == origin/main. Confirm what git status --porcelain ACTUALLY reports
# before trusting the case — Task 3's own first MM fixture was a false
# positive for skipping exactly this check.
echo "1.0.1" > "${CLI}/versions/cli"
echo "1.0.1" > "${CLI}/versions/cli.stamp"
/usr/bin/git -C "${CLI}" add versions/cli versions/cli.stamp
st="$(/usr/bin/git -C "${CLI}" status --porcelain --untracked-files=all)"
check_contains "case (a) fixture: versions/cli is really staged-modified (M )" "${st}" "M  versions/cli"
check_contains "case (a) fixture: versions/cli.stamp is really staged-added (A )" "${st}" "A  versions/cli.stamp"
out="$(assert_release_origin "release repo" "${CLI}" "${CLI}" strict versions/cli versions/cli.stamp 2>&1)" && r=0 || r=1
check "case (a): tolerance admits the staged versions/cli + versions/cli.stamp bump" "${r}" "0"
check "case (a): case (a) is silent" "${out}" ""

# (b) — an additional staged file the tolerance does not name (a dispatcher
# bump landing in the same tree) is refused even though versions/cli and
# versions/cli.stamp are still exactly as (a) left them: the tolerance is an
# exact set, not "staged is fine now".
echo "9.9.9" > "${CLI}/versions/burrowee"
/usr/bin/git -C "${CLI}" add versions/burrowee
st="$(/usr/bin/git -C "${CLI}" status --porcelain --untracked-files=all)"
check_contains "case (b) fixture: versions/burrowee is really staged-added (A )" "${st}" "A  versions/burrowee"
out="$(assert_release_origin "release repo" "${CLI}" "${CLI}" strict versions/cli versions/cli.stamp 2>&1)" && r=0 || r=1
check "case (b): an unlisted staged file is refused" "${r}" "1"
/usr/bin/git -C "${CLI}" reset --quiet -- versions/burrowee
rm -f "${CLI}/versions/burrowee"

# (c) — versions/cli staged AND further modified in the worktree on top: the
# stamp would have been computed from the worktree file while the marker
# commit records the index, so this MUST be refused even though the path is
# on the allow-list. Verify the porcelain code really is "MM", not "AM" —
# the exact substitution that made Task 3's original fixture unfalsifiable.
echo "more" >> "${CLI}/versions/cli"
st="$(/usr/bin/git -C "${CLI}" status --porcelain --untracked-files=all)"
check_contains "case (c) fixture: versions/cli is really MM (staged AND worktree-modified)" "${st}" "MM versions/cli"
out="$(assert_release_origin "release repo" "${CLI}" "${CLI}" strict versions/cli versions/cli.stamp 2>&1)" && r=0 || r=1
check "case (c): MM on an allowed path is refused (staged only, not staged-plus-dirty)" "${r}" "1"
/usr/bin/git -C "${CLI}" checkout --quiet -- versions/cli

# (d) — (a) plus an untracked file anywhere in the tree: refused exactly as
# tree_clean refuses it, tolerance or not.
touch "${CLI}/stray.txt"
st="$(/usr/bin/git -C "${CLI}" status --porcelain --untracked-files=all)"
check_contains "case (d) fixture: stray.txt is really untracked (?? )" "${st}" "?? stray.txt"
out="$(assert_release_origin "release repo" "${CLI}" "${CLI}" strict versions/cli versions/cli.stamp 2>&1)" && r=0 || r=1
check "case (d): an untracked file is refused even with an allow-list" "${r}" "1"
rm -f "${CLI}/stray.txt"

# (f) — the SAME (a) fixture (still staged M + A, nothing else), called with
# NO trailing paths at all: this is what every call site other than the
# release-repo --distribute-only one actually does, so it must refuse exactly
# like the pre-tolerance guard did. This is the permanent proof that the
# tolerance is opt-in per call, not a default weakening.
out="$(assert_release_origin "release repo" "${CLI}" "${CLI}" strict 2>&1)" && r=0 || r=1
check "case (f): the same fixture with no trailing paths is refused (default unchanged)" "${r}" "1"
check_contains "case (f): the no-tolerance refusal is the dirty-tree message" "${out}" "source tree is dirty"

# Hygiene: (a)'s fixture is back to its passing baseline after (b)-(f), none
# of which should have left it dirty in a way (a) itself would not pass.
out="$(assert_release_origin "release repo" "${CLI}" "${CLI}" strict versions/cli versions/cli.stamp 2>&1)" && r=0 || r=1
check "case (a)-(f): fixture restored to the passing baseline" "${r}" "0"

# (e) — the bump COMMITTED instead of staged: the tree is clean (nothing
# staged, nothing untracked), so tree_clean_except_staged passes trivially
# regardless of the tolerance, and assert_release_origin falls through to the
# sync-status arm, where the un-pushed commit is one ahead of origin/main.
# This is the case that proves the tolerance does not paper over the sync
# check — a committed bump is refused for a completely different reason.
CLI_AHEAD="$(new_origin_and_clone task5-cli-ahead)"
mkdir -p "${CLI_AHEAD}/versions"
echo "1.0.0" > "${CLI_AHEAD}/versions/cli"
/usr/bin/git -C "${CLI_AHEAD}" add versions/cli
/usr/bin/git -C "${CLI_AHEAD}" commit --quiet -m "seed versions/cli"
/usr/bin/git -C "${CLI_AHEAD}" push --quiet origin main
echo "1.0.1" > "${CLI_AHEAD}/versions/cli"
echo "1.0.1" > "${CLI_AHEAD}/versions/cli.stamp"
/usr/bin/git -C "${CLI_AHEAD}" add versions/cli versions/cli.stamp
/usr/bin/git -C "${CLI_AHEAD}" commit --quiet -m "bump versions/cli"
st="$(/usr/bin/git -C "${CLI_AHEAD}" status --porcelain --untracked-files=all)"
check "case (e) fixture: worktree is clean once the bump is committed" "${st}" ""
out="$(assert_release_origin "release repo" "${CLI_AHEAD}" "${CLI_AHEAD}" strict versions/cli versions/cli.stamp 2>&1)" && r=0 || r=1
check "case (e): a committed (not staged) bump is refused, 1 ahead of origin" "${r}" "1"
check_contains "case (e): the refusal message names 'ahead'" "${out}" "ahead"

# (g)/(h) — the scoping decision itself, no repo involved: nothing for a full
# cut, exactly the two component paths for --distribute-only.
check "case (g): staged_tolerance_for 0 cli yields nothing" "$(staged_tolerance_for 0 cli)" ""
staged_tolerance_for 0 cli >/dev/null && r=0 || r=1
check "case (g): staged_tolerance_for 0 cli returns 0" "${r}" "0"
check "case (h): staged_tolerance_for 1 cli names exactly versions/cli and its stamp" \
    "$(staged_tolerance_for 1 cli)" "$(printf 'versions/cli\nversions/cli.stamp')"

echo
if [ "${fail}" = 0 ]; then echo "ALL OK"; else echo "TESTS FAILED"; exit 1; fi
