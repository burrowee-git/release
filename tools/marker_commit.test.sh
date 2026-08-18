#!/usr/bin/env bash
# marker_commit.test.sh — unit tests for tools/marker_commit.sh.
#
# Exercises marker_commit() directly against throwaway repos under a temp dir.
# NO part of the release path runs: release.sh is never invoked, nothing is
# built, signed, notarized or published.
#
# The two cases that matter are deliberately opposed, and they fail for
# DIFFERENT reasons:
#
#   - "nothing staged"  must SUCCEED and make no commit;
#   - "git commit really fails" (a rejecting pre-commit hook, a held
#     index.lock) must still ABORT.
#
# A `git commit … || true` implementation passes the first and fails the
# second, which is the whole point: without the second case the suite cannot
# tell the fix from the bug it replaces.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HERE}/marker_commit.sh"

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
trap 'chmod -R u+w "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig"   # keep the operator's identity/hooks out of it
/usr/bin/git config --file "${GIT_CONFIG_GLOBAL}" user.name  "Marker Commit Test"
/usr/bin/git config --file "${GIT_CONFIG_GLOBAL}" user.email "marker-commit@test.invalid"
/usr/bin/git config --file "${GIT_CONFIG_GLOBAL}" init.defaultBranch main

# new_release_repo <name> — a repo shaped like the release repo at the moment
# the marker step runs: versions/<comp> and versions/<comp>.stamp already
# committed by a previous cut. Prints the repo path.
new_release_repo() {
    local repo="${WORK}/$1"
    /usr/bin/git init --quiet "${repo}"
    mkdir -p "${repo}/versions" "${repo}/cli"
    echo "0.2.0"                          > "${repo}/versions/cli"
    echo "v0.2.0.2026.08.18.2ae6a7a9"     > "${repo}/versions/cli.stamp"
    echo "#!/bin/sh"                      > "${repo}/cli/install.sh"
    /usr/bin/git -C "${repo}" add versions cli
    /usr/bin/git -C "${repo}" commit --quiet -m "[RELEASED: cli] 2026-08-18 v0.2.0.2026.08.18.2ae6a7a9"
    printf '%s' "${repo}"
}

commit_count() { /usr/bin/git -C "$1" rev-list --count HEAD; }

# ── check 1: the production case — a re-cut at an identical stamp ────────────
# versions/cli, versions/cli.stamp and the regenerated bootstraps are
# byte-identical to HEAD, so `git add` leaves an EMPTY index. This is exactly
# what killed the 2026-08-18 cut after every irreversible step had succeeded.
EMPTY="$(new_release_repo empty-diff)"
before="$(commit_count "${EMPTY}")"
# Re-write the same bytes and stage them, as the cut's gen-bootstraps + version
# steps do. Staging identical content is a no-op against the index.
echo "0.2.0"                      > "${EMPTY}/versions/cli"
echo "v0.2.0.2026.08.18.2ae6a7a9" > "${EMPTY}/versions/cli.stamp"
/usr/bin/git -C "${EMPTY}" add versions/cli versions/cli.stamp cli/install.sh
out="$(marker_commit "${EMPTY}" "[RELEASED: cli] 2026-08-18 v0.2.0.2026.08.18.2ae6a7a9" 2>&1)"; r=$?
check "empty-diff: returns 0 instead of aborting the cut" "${r}" "0"
check "empty-diff: makes no commit" "$(commit_count "${EMPTY}")" "${before}"
check_contains "empty-diff: says plainly that there was nothing to record" "${out}" "nothing to record"

# ── check 2: the ordinary case — a real bump is committed ───────────────────
# Without this, check 1 could be satisfied by a marker step that never commits
# anything at all.
WORKED="$(new_release_repo real-work)"
before="$(commit_count "${WORKED}")"
echo "0.2.1" > "${WORKED}/versions/cli"
/usr/bin/git -C "${WORKED}" add versions/cli
marker_commit "${WORKED}" "[RELEASED: cli] 2026-08-18 v0.2.1.2026.08.18.deadbeef" >/dev/null 2>&1; r=$?
check "real bump: returns 0" "${r}" "0"
check "real bump: makes exactly one commit" \
    "$(( $(commit_count "${WORKED}") - before ))" "1"
check "real bump: records the marker message verbatim" \
    "$(/usr/bin/git -C "${WORKED}" log -1 --pretty=%s)" \
    "[RELEASED: cli] 2026-08-18 v0.2.1.2026.08.18.deadbeef"

# ── check 3: a REAL commit failure must still abort ─────────────────────────
# A rejecting pre-commit hook stands in for every real reason `git commit`
# exits non-zero — a hook, a bad committer identity, an unwritable object
# store. `git commit … || true` and `set +e` swallow this one exactly as
# effectively as they swallow the empty diff; the explicit empty-diff check
# does not.
HOOK="$(new_release_repo hook-reject)"
mkdir -p "${HOOK}/.git/hooks"
printf '#!/bin/sh\necho "hook: refusing" >&2\nexit 1\n' > "${HOOK}/.git/hooks/pre-commit"
chmod +x "${HOOK}/.git/hooks/pre-commit"
before="$(commit_count "${HOOK}")"
echo "0.2.1" > "${HOOK}/versions/cli"
/usr/bin/git -C "${HOOK}" add versions/cli
out="$(marker_commit "${HOOK}" "[RELEASED: cli] 2026-08-18 v0.2.1.2026.08.18.deadbeef" 2>&1)"; r=$?
[ "${r}" -ne 0 ] && rr=nonzero || rr=zero
check "hook rejection: returns non-zero (a blanket '|| true' would return 0)" "${rr}" "nonzero"
check "hook rejection: makes no commit" "$(commit_count "${HOOK}")" "${before}"

# ── check 4: a second, hook-independent real failure ────────────────────────
# A held index.lock is the failure mode an operator actually meets when a cut
# is run twice at once. It proves check 3 is not merely detecting "hooks run".
LOCKED="$(new_release_repo index-lock)"
before="$(commit_count "${LOCKED}")"
echo "0.2.1" > "${LOCKED}/versions/cli"
/usr/bin/git -C "${LOCKED}" add versions/cli
: > "${LOCKED}/.git/index.lock"
out="$(marker_commit "${LOCKED}" "[RELEASED: cli] 2026-08-18 v0.2.1.2026.08.18.deadbeef" 2>&1)"; r=$?
rm -f "${LOCKED}/.git/index.lock"
[ "${r}" -ne 0 ] && rr=nonzero || rr=zero
check "index.lock: returns non-zero" "${rr}" "nonzero"
check "index.lock: makes no commit" "$(commit_count "${LOCKED}")" "${before}"

# ── check 5: nothing staged, but the WORKTREE is dirty ──────────────────────
# `git commit` with no pathspec commits the INDEX, so an unstaged edit is not
# something the marker step was ever going to record. It must skip, not abort,
# and it must not sweep the unstaged edit into a commit.
DIRTY="$(new_release_repo dirty-worktree)"
before="$(commit_count "${DIRTY}")"
echo "scratch" > "${DIRTY}/versions/cli"     # modified, NOT staged
out="$(marker_commit "${DIRTY}" "[RELEASED: cli] 2026-08-18 v0.2.0.2026.08.18.2ae6a7a9" 2>&1)"; r=$?
check "dirty worktree, empty index: returns 0" "${r}" "0"
check "dirty worktree, empty index: makes no commit" "$(commit_count "${DIRTY}")" "${before}"

# ── check 6: every marker site in release.sh goes through marker_commit ─────
# The defect existed at FOUR sites (two distribute-only, two full-cut); fixing
# some of them is not fixing it. This is a structural assertion in the same
# spirit as cmd/rkit's TestReleasePublishesEveryRenderedArtifact, which pins
# the scp + git add sites the same way.
RELEASE_SH="${HERE}/release.sh"
raw_commits="$(grep -c '^[[:space:]]*git commit -m "\[RELEASED:' "${RELEASE_SH}" || true)"
check "release.sh: no bare 'git commit -m \"[RELEASED:' remains" "${raw_commits}" "0"
marker_calls="$(grep -c '^[[:space:]]*marker_commit ' "${RELEASE_SH}" || true)"
check "release.sh: all four marker sites call marker_commit" "${marker_calls}" "4"
check_contains "release.sh: sources marker_commit.sh" \
    "$(grep 'tools/marker_commit.sh' "${RELEASE_SH}" || true)" "source"

echo
if [ "${fail}" = 0 ]; then echo "ALL MARKER-COMMIT CHECKS PASSED"; else echo "MARKER-COMMIT CHECKS FAILED"; fi
exit "${fail}"
