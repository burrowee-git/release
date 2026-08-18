#!/usr/bin/env bash
# marker_commit.sh — the [RELEASED: <comp>] marker commit, as a predicate
# sourced by tools/release.sh. Same split as tools/cut_origin.sh and
# tools/apple_sign.sh: the decision lives here so tools/marker_commit.test.sh
# can exercise it against throwaway repos with no part of the release path
# running.
#
# WHY THIS EXISTS: `git commit` treats an empty index as an error. Re-cutting a
# component at an identical stamp leaves versions/<comp>, versions/<comp>.stamp
# and the regenerated bootstraps byte-identical to HEAD, so `git add` stages
# nothing, `git commit` exits 1, and `set -e` killed the cut AFTER the build,
# the signature, the notarization, the GitHub Release and the scp had all
# succeeded — reporting failure on a complete publish, and (inside
# `release.sh all`) dropping every component queued behind it. Hit three times
# on 2026-08-18.
#
# WHY NOT `git commit … || true`: that swallows a rejecting hook, a held
# index.lock, an unwritable object store and a bad committer identity just as
# thoroughly as it swallows the empty diff. The empty-diff condition is
# therefore tested for EXPLICITLY, before committing, and every other non-zero
# from `git commit` aborts the cut exactly as it did before.
#
# WHY SKIP RATHER THAN `--allow-empty`: nothing reads the markers. The
# authoritative record of what was cut is versions/<comp> + versions/<comp>.stamp
# (tools/cut-status.sh reads the stamp files) and the GitHub Release tag
# (tools/prune-releases.sh reads the releases API); no `git log` anywhere in
# tools/, cmd/ or internal/ parses commit messages. And the empty diff arises
# precisely BECAUSE the semver and stamp are unchanged — which means the marker
# for that stamp is already in history, put there by the cut that first
# published it. `--allow-empty` would append a SECOND marker naming the SAME
# stamp, turning "one marker per stamp" into "several", which is worse for a
# future reader than the gap it fills. It would also leave the repo one commit
# ahead of origin/main (release.sh never pushes — tools/RUNBOOK.md, Residual 2),
# blocking the next cut on origin_sync_status until an operator pushes a commit
# carrying no information.

# marker_commit <repo-dir> <message> — commit whatever the caller staged as the
# release marker.
#
# Callers `git add` the paths they mean to record and this commits the INDEX
# (no pathspec), which is what lets `rkit build`'s pre-staged versions/<comp>
# and versions/<comp>.stamp ride the same commit for free.
#
# Returns 0 and prints why when the index holds nothing to record. Returns
# git's own status for every other failure.
#
# The `if` is deliberately one-sided: `git diff --cached --quiet` exits 0 for
# "index matches HEAD", 1 for "there are staged changes", and >1 if it could
# not tell (no HEAD, unreadable object store). Only a literal 0 takes the skip
# branch — an ERROR falls through to `git commit`, which then fails loudly.
# The uncertain case must never look like "nothing to record".
marker_commit() {
    local dir="$1" msg="$2"
    if /usr/bin/git -C "${dir}" diff --cached --quiet; then
        echo "→ marker: nothing to record — version, stamp and bootstraps already match HEAD; no commit made"
        return 0
    fi
    /usr/bin/git -C "${dir}" commit -m "${msg}"
}
