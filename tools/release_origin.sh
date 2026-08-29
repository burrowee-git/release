#!/usr/bin/env bash
# release_origin.sh — where a release cut is allowed to build from, as predicates
# sourced by tools/release.sh.
#
# A cut stamps a version onto whatever commit it finds in the tree it was
# pointed at, so the choice of tree is a correctness property: if the tree is
# not origin/main, the published version names a commit the world cannot fetch.
# These checks are the last thing between a stale checkout and a published
# artifact, which is why they live here as functions rather than inline in the
# orchestrator — tools/release_origin.test.sh exercises them directly, with no part
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

# beta_worktree_for <registry-main-dir> — the beta cut origin, DERIVED from the
# registry main path rather than configured on its own: there is no separate
# registry entry for a beta worktree, so the two can never drift apart.
# <code>/beta, sibling to the main folder. Prints an unresolved
# (".."-bearing) but absolute path; callers that need the canonical form
# resolve it themselves (e.g. `cd "$(beta_worktree_for "$m")" && pwd`), the
# same way is_primary_worktree's callers resolve git's own path output.
beta_worktree_for() {
    printf '%s/../beta' "$1"
}

# is_linked_worktree_of <dir> <main> — dir is a LINKED worktree belonging to
# main's repo (not main itself, not some unrelated repo that happens to sit at
# the derived path). Mirrors is_primary_worktree's git-dir/git-common-dir
# comparison, plus a second comparison against main's own common dir so a
# same-shaped worktree of a DIFFERENT repo cannot pass.
is_linked_worktree_of() {
    local dir="$1" main="$2" git_dir common_dir main_common
    git_dir="$(/usr/bin/git -C "${dir}" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
    common_dir="$(/usr/bin/git -C "${dir}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    main_common="$(/usr/bin/git -C "${main}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ "${git_dir}" != "${common_dir}" ] && [ "${common_dir}" = "${main_common}" ]
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

# tree_clean_except_staged <dir> [allowed-path...] — tree_clean, except that the
# named paths may be STAGED, and nothing else may be anything. With no allowed
# paths it IS tree_clean, which is what every other tree still gets.
#
# One caller: the release repo under `release.sh --distribute-only`, where the
# preceding `rkit build` staged versions/<comp> and versions/<comp>.stamp so both
# ride the [RELEASED] marker commit (cmd/rkit `buildRun`). The full-cut path
# already builds from a release repo that differs from origin/main by exactly that
# bump, because it bumps AFTER this guard runs (`assert_release_origins` at the distribute/full-cut dispatch vs
# resolve_comp_stamp) — so this re-establishes an existing exemption for a bump
# that moved into the produce half, rather than creating a new one.
#
# The tolerance is "M " (index-modified) or "A " (index-added) with a CLEAN
# worktree. "MM" is refused: the stamp was computed from the worktree file while
# the marker commit records the index, so the published and recorded versions
# could differ. Untracked is refused, exactly as in tree_clean.
tree_clean_except_staged() {
    local dir="$1"; shift
    local line code path allowed matched
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        code="${line:0:2}"
        path="${line:3}"
        case "${code}" in
            'M '|'A ') ;;
            *) return 1 ;;
        esac
        matched=1
        for allowed in "$@"; do
            if [ "${path}" = "${allowed}" ]; then matched=0; break; fi
        done
        [ "${matched}" = 0 ] || return 1
    done <<EOF
$(/usr/bin/git -C "${dir}" status --porcelain --untracked-files=all 2>/dev/null)
EOF
    return 0
}

# staged_tolerance_for <distribute_only> <comp> — the paths the RELEASE REPO may
# carry staged, one per line. Empty for a full cut: that path bumps
# versions/<comp> itself, AFTER this guard has run, so nothing is staged when the
# guard looks.
#
# versions/burrowee is deliberately NOT included. A dispatcher bump is a manual
# operator step (release.sh's dispatcher note), so there is no tool-created
# deadlock to break — only a commit to make in the ordinary order. Widening the
# tolerance to a third path would buy a case nothing produces.
#
# It lives here rather than inline in release.sh's dispatch branch so this
# decision is unit-testable without any part of the release path running.
staged_tolerance_for() {
    local distribute_only="$1" comp="$2"
    [ "${distribute_only}" = 1 ] || return 0
    [ -n "${comp}" ] || return 0
    printf '%s\n%s\n' "versions/${comp}" "versions/${comp}.stamp"
}

# origin_sync_status <dir> [branch] — fetches origin/<branch> (branch defaults
# to main, so every pre-existing single-arg call keeps fetching origin/main
# unchanged) and prints the relationship between HEAD and it: in-sync |
# behind:<n> | ahead:<n> | diverged:<ahead>:<behind> | fetch-failed. Returns 0
# only for in-sync.
#
# Compares against FETCH_HEAD rather than refs/remotes/origin/<branch>:
# FETCH_HEAD is exactly what this call just fetched, whereas the
# remote-tracking ref is only opportunistically updated by
# `git fetch origin <branch>` and can be stale from an earlier fetch —
# comparing against it is the very mistake this check exists to catch.
#
# A failed fetch is NOT treated as "assume in-sync" or "compare against what we
# have": a delayed cut costs minutes, and a wrongly stamped artifact cannot be
# withdrawn because a published version is never re-pointed.
#
# Read-only. It fetches (which touches only FETCH_HEAD and remote refs) and
# never merges, pulls, checks out or stashes: a release tool that moves the
# operator's checkout turns a typo into a shipped artifact.
origin_sync_status() {
    local dir="$1" branch="${2:-main}" counts ahead behind
    if ! /usr/bin/git -C "${dir}" fetch --quiet origin "${branch}" 2>/dev/null; then
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

# assert_release_origin <label> <dir> <expected> <mode> [channel] [allowed-staged...]
# — the whole guard for one tree, cheapest check first so a local mistake fails
# in milliseconds and only a fully-local-clean tree costs a network round trip.
#
# mode=strict  → first failure prints "✗ …" to stderr and returns 1 (a real cut)
# mode=report  → findings print "⚠ …" to stderr and 0 is returned (--dry-run,
#                which publishes nothing, so an override is a legitimate
#                rehearsal rather than an error)
#
# label is the component name (or "release repo") and appears in every message:
# a cut reads six trees, so "which one" is the first thing an operator needs.
#
# [channel] is stable (default) or beta, consumed from the next positional
# ONLY when it is shaped like a channel token: exactly "stable"/"beta" is
# accepted; anything containing "/" is assumed to be the first
# [allowed-staged...] entry (every real tolerance path looks like
# versions/<comp>[.stamp] — staged_tolerance_for never emits a bare word) and
# left alone; anything else — empty, wrong case ("Beta"), misspelled
# ("betaa") — is a caller bug, not a tree finding, so it is refused outright
# with "✗ <label> unknown channel: <token>" and returns 1 UNCONDITIONALLY,
# even under mode=report. This is what lets every pre-existing call site
# (release.sh, test-produce-then-distribute.sh — neither of which knows
# about channels) keep working unmodified while still closing the door on a
# computed channel variable (a future caller) landing here empty or
# misspelled and silently cutting from the wrong tree. beta redirects the
# whole guard at a second, structurally different origin:
# <registry-main>/../beta (beta_worktree_for), which must be a
# LINKED worktree of the registry main repo (is_linked_worktree_of) — never
# configured separately, so it cannot drift from the registry entry — on
# branch beta, clean, == origin/beta. A missing beta worktree is refused with
# its path and the fix (spec §5.2); nothing here ever creates one.
#
# [allowed-staged...] is the output of staged_tolerance_for — the paths THIS
# ONE tree may carry staged instead of clean. It applies only to the clean-tree
# check below, and only to the single <dir> being asserted here; every other
# tree a caller asserts in the same run gets its own (typically empty) list.
assert_release_origin() {
    local label="$1" dir="$2" expected="$3" mode="$4"; shift 4
    local channel=stable
    if [ "$#" -gt 0 ]; then
        case "$1" in
            stable|beta) channel="$1"; shift ;;
            */*) : ;; # path-shaped — the first [allowed-staged...] entry, not a channel
            *)
                printf '✗ %s unknown channel: %s\n    a channel positional must be exactly stable or beta\n' \
                    "${label}" "$1" >&2
                return 1
                ;;
        esac
    fi
    local -a allowed=("$@")
    local mark="✗" rc=1
    if [ "${mode}" = report ]; then mark="⚠"; rc=0; fi

    local want_branch=main
    if [ "${channel}" = beta ]; then
        want_branch=beta
        local beta_dir
        beta_dir="$(beta_worktree_for "${expected}")"
        if [ ! -d "${beta_dir}" ]; then
            printf '%s %s beta worktree missing: %s — open a beta cycle first\n' \
                "${mark}" "${label}" "${beta_dir}" >&2
            [ "${mode}" = report ] || return 1
        fi
        beta_dir="$(cd "${beta_dir}" 2>/dev/null && pwd)" || beta_dir=""
        if [ "$(cd "${dir}" 2>/dev/null && pwd)" != "${beta_dir}" ]; then
            printf '%s %s beta source must be the registry beta worktree\n    expected: %s\n    got:      %s\n' \
                "${mark}" "${label}" "${beta_dir}" "${dir}" >&2
            [ "${mode}" = report ] || return 1
        fi
        if ! is_linked_worktree_of "${dir}" "${expected}"; then
            printf '%s %s beta source is not a linked worktree of %s: %s\n' \
                "${mark}" "${label}" "${expected}" "${dir}" >&2
            [ "${mode}" = report ] || return 1
        fi
    else
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
    fi

    local branch
    branch="$(worktree_branch "${dir}")"
    if [ "${branch}" != "${want_branch}" ]; then
        printf '%s %s source not on %s (on %s): %s\n' "${mark}" "${label}" "${want_branch}" "${branch}" "${dir}" >&2
        [ "${mode}" = report ] || return 1
    fi
    if ! tree_clean_except_staged "${dir}" ${allowed[@]+"${allowed[@]}"}; then
        printf '%s %s source tree is dirty: %s\n    commit or clean it — a cut may not stamp a working-tree state\n' \
            "${mark}" "${label}" "${dir}" >&2
        if [ "${#allowed[@]}" -gt 0 ]; then
            printf '    (staged is tolerated for exactly: %s)\n' "${allowed[*]}" >&2
        fi
        [ "${mode}" = report ] || return 1
    fi

    # Named sync_status, not status: `status` is a read-only builtin variable
    # in zsh (and shells that source this file for debugging outside the
    # release.sh bash entry point), so `local status` aborts with "read-only
    # variable: status" — right at this check, the one the design calls the
    # hole that matters.
    local sync_status
    sync_status="$(origin_sync_status "${dir}" "${want_branch}")" || true
    case "${sync_status}" in
        in-sync) return 0 ;;
        behind:*)
            printf '%s %s source is %s commit(s) behind origin/%s: %s\n    run '"'"'git pull --ff-only'"'"' there, then re-run the cut\n' \
                "${mark}" "${label}" "${sync_status#behind:}" "${want_branch}" "${dir}" >&2 ;;
        ahead:*)
            printf '%s %s source is %s commit(s) ahead of origin/%s: %s\n    merge it through a PR first — a cut may only stamp a commit that exists on the remote\n' \
                "${mark}" "${label}" "${sync_status#ahead:}" "${want_branch}" "${dir}" >&2 ;;
        diverged:*)
            local counts="${sync_status#diverged:}"
            printf '%s %s source has diverged from origin/%s (%s ahead, %s behind): %s\n' \
                "${mark}" "${label}" "${want_branch}" "${counts%%:*}" "${counts##*:}" "${dir}" >&2 ;;
        fetch-failed)
            printf '%s %s could not fetch origin/%s: %s\n    a cut may not proceed against a stale remote ref — fix connectivity or credentials and re-run\n' \
                "${mark}" "${label}" "${want_branch}" "${dir}" >&2 ;;
        *)
            printf '%s %s unrecognised origin status '"'"'%s'"'"': %s\n    a cut may not proceed on an unknown status — investigate before re-running\n' \
                "${mark}" "${label}" "${sync_status}" "${dir}" >&2 ;;
    esac
    return "${rc}"
}
