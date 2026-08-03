#!/usr/bin/env bash
# cut_origin.sh — where a release cut is allowed to build from, as predicates
# sourced by tools/release.sh.
#
# A cut stamps a version onto whatever commit it finds in the tree it was
# pointed at, so the choice of tree is a correctness property: if the tree is
# not origin/main, the published version names a commit the world cannot fetch.
# These checks are the last thing between a stale checkout and a published
# artifact, which is why they live here as functions rather than inline in the
# orchestrator — tools/cut_origin.test.sh exercises them directly, with no part
# of the release path running. Same split as tools/apple_sign.sh and
# tools/vulncheck.sh.
#
# Design: docs/specs/2026-08-03-cut-origin-and-worktree-flow-design.md
# (burrowee-git/resources).

# is_registry_source <dir> <expected> — dir is the registry main folder for its
# component. `expected` is release.sh's OWN default for that component, so
# this is the table a CUT is checked against, not a second definition
# maintained here. That table is known to be duplicated elsewhere
# (tools/cut-status.sh, cmd/rkit/harness.go) — this predicate does not claim
# those don't exist, only that a cut's pass/fail can never disagree with
# release.sh's own idea of the registry path.
is_registry_source() {
    [ "$1" = "$2" ]
}

# is_primary_worktree <dir> — dir is git's ORIGINAL checkout, not a linked
# worktree. This is the rule itself in checkable form: --git-dir and
# --git-common-dir coincide only in the primary worktree (a linked one reports
# <main>/.git/worktrees/<name> for the former). --path-format=absolute is what
# makes the comparison sound — --git-common-dir otherwise prints a path
# relative to the working directory.
is_primary_worktree() {
    local dir="$1" git_dir common_dir
    git_dir="$(/usr/bin/git -C "${dir}" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
    common_dir="$(/usr/bin/git -C "${dir}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ "${git_dir}" = "${common_dir}" ]
}

# worktree_branch <dir> — prints the checked-out branch name ("HEAD" when
# detached). Printing rather than asserting keeps the branch available for the
# failure message. Non-repo inputs make git exit 128; the predicate contract is
# 0/1, so the failure must be normalised via || return 1.
worktree_branch() {
    /usr/bin/git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null || return 1
}

# tree_clean <dir> — no modifications AND no untracked files. Untracked counts
# as dirty on purpose: a stray file in a source tree is as likely to end up
# inside a build as a modified one. --untracked-files=all so a repo-local
# status.showUntrackedFiles=no cannot quietly retire the untracked half of
# this check — the config lives with the tree being asserted, not with the
# operator running the guard.
tree_clean() {
    [ -z "$(/usr/bin/git -C "$1" status --porcelain --untracked-files=all 2>/dev/null)" ]
}

# origin_sync_status <dir> — fetches origin/main and prints the relationship
# between HEAD and it: in-sync | behind:<n> | ahead:<n> |
# diverged:<ahead>:<behind> | fetch-failed. Returns 0 only for in-sync.
#
# Compares against FETCH_HEAD rather than refs/remotes/origin/main: FETCH_HEAD
# is exactly what this call just fetched, whereas the remote-tracking ref is
# only opportunistically updated by `git fetch origin main` and can be stale
# from an earlier fetch — comparing against it is the very mistake this check
# exists to catch.
#
# A failed fetch is NOT treated as "assume in-sync" or "compare against what we
# have": a delayed cut costs minutes, and a wrongly stamped artifact cannot be
# withdrawn because a published version is never re-pointed.
#
# Read-only. It fetches (which touches only FETCH_HEAD and remote refs) and
# never merges, pulls, checks out or stashes: a release tool that moves the
# operator's checkout turns a typo into a shipped artifact.
origin_sync_status() {
    local dir="$1" counts ahead behind
    if ! /usr/bin/git -C "${dir}" fetch --quiet origin main 2>/dev/null; then
        printf 'fetch-failed'
        return 1
    fi
    counts="$(/usr/bin/git -C "${dir}" rev-list --left-right --count HEAD...FETCH_HEAD 2>/dev/null)" || {
        printf 'fetch-failed'
        return 1
    }
    ahead="${counts%%[[:space:]]*}"
    behind="${counts##*[[:space:]]}"
    if [ "${ahead}" = 0 ] && [ "${behind}" = 0 ]; then
        printf 'in-sync'
        return 0
    fi
    if [ "${ahead}" != 0 ] && [ "${behind}" != 0 ]; then
        printf 'diverged:%s:%s' "${ahead}" "${behind}"
    elif [ "${behind}" != 0 ]; then
        printf 'behind:%s' "${behind}"
    else
        printf 'ahead:%s' "${ahead}"
    fi
    return 1
}

# assert_cut_origin <label> <dir> <expected> <mode> — the whole guard for one
# tree, cheapest check first so a local mistake fails in milliseconds and only
# a fully-local-clean tree costs a network round trip.
#
# mode=strict  → first failure prints "✗ …" to stderr and returns 1 (a real cut)
# mode=report  → findings print "⚠ …" to stderr and 0 is returned (--dry-run,
#                which publishes nothing, so an override is a legitimate
#                rehearsal rather than an error)
#
# label is the component name (or "release repo") and appears in every message:
# a cut reads six trees, so "which one" is the first thing an operator needs.
assert_cut_origin() {
    local label="$1" dir="$2" expected="$3" mode="$4"
    local mark="✗" rc=1
    if [ "${mode}" = report ]; then mark="⚠"; rc=0; fi

    if ! is_registry_source "${dir}" "${expected}"; then
        printf '%s %s source must be the registry main folder\n    expected: %s\n    got:      %s\n    (BURROWEE_SRC_* overrides are permitted only with --dry-run)\n' \
            "${mark}" "${label}" "${expected}" "${dir}" >&2
        [ "${mode}" = report ] || return 1
    fi
    if ! is_primary_worktree "${dir}"; then
        printf '%s %s source is a linked worktree, not the main-branch folder: %s\n    a cut runs only from the primary checkout on main\n' \
            "${mark}" "${label}" "${dir}" >&2
        [ "${mode}" = report ] || return 1
    fi
    local branch
    branch="$(worktree_branch "${dir}")"
    if [ "${branch}" != main ]; then
        printf '%s %s source not on main (on %s): %s\n' "${mark}" "${label}" "${branch}" "${dir}" >&2
        [ "${mode}" = report ] || return 1
    fi
    if ! tree_clean "${dir}"; then
        printf '%s %s source tree is dirty: %s\n    commit or clean it — a cut may not stamp a working-tree state\n' \
            "${mark}" "${label}" "${dir}" >&2
        [ "${mode}" = report ] || return 1
    fi

    # Named sync_status, not status: `status` is a read-only builtin variable
    # in zsh (and shells that source this file for debugging outside the
    # release.sh bash entry point), so `local status` aborts with "read-only
    # variable: status" — right at this check, the one the design calls the
    # hole that matters.
    local sync_status
    sync_status="$(origin_sync_status "${dir}")" || true
    case "${sync_status}" in
        in-sync) return 0 ;;
        behind:*)
            printf '%s %s source is %s commit(s) behind origin/main: %s\n    run '"'"'git pull --ff-only'"'"' there, then re-run the cut\n' \
                "${mark}" "${label}" "${sync_status#behind:}" "${dir}" >&2 ;;
        ahead:*)
            printf '%s %s source is %s commit(s) ahead of origin/main: %s\n    merge it through a PR first — a cut may only stamp a commit that exists on the remote\n' \
                "${mark}" "${label}" "${sync_status#ahead:}" "${dir}" >&2 ;;
        diverged:*)
            local counts="${sync_status#diverged:}"
            printf '%s %s source has diverged from origin/main (%s ahead, %s behind): %s\n' \
                "${mark}" "${label}" "${counts%%:*}" "${counts##*:}" "${dir}" >&2 ;;
        fetch-failed)
            printf '%s %s could not fetch origin/main: %s\n    a cut may not proceed against a stale remote ref — fix connectivity or credentials and re-run\n' \
                "${mark}" "${label}" "${dir}" >&2 ;;
        *)
            printf '%s %s unrecognised origin status '"'"'%s'"'"': %s\n    a cut may not proceed on an unknown status — investigate before re-running\n' \
                "${mark}" "${label}" "${sync_status}" "${dir}" >&2 ;;
    esac
    return "${rc}"
}
