#!/usr/bin/env bash
# batch.sh — what a multi-component cut actually got through, as state that
# survives the cut dying. Sourced by tools/release.sh; tested directly by
# tools/batch.test.sh with no part of the release path running.
#
# WHY THIS EXISTS: `release.sh all` cuts cli, gateway, edge, agent in order
# under `set -e`. When one fails, the script dies where it stands and the
# components queued behind it never run — and nothing in the output says so.
# On 2026-08-18 cli published, its marker commit aborted, and gateway and edge
# silently never ran; the run read as one failure when it was one success and
# two omissions.
#
# WHY AN EXIT TRAP RATHER THAN A RETURN-CHECKING LOOP: the obvious shape,
# `if do_release "${comp}"; then …`, is wrong twice over. It suspends `set -e`
# for the whole body of do_release, so every unchecked failure inside it —
# a failed `gh release create`, a failed scp — would stop aborting and the cut
# would carry on to the next step. And it cannot report at all when do_release
# calls `exit` directly, which release.sh's failure paths do far more often
# than they `return`. Hanging the summary off the EXIT trap keeps the runner
# call bare, so `set -e` semantics are exactly what they were, and still
# reports when the shell is torn down under it.
#
# STOP-ON-FAILURE IS KEPT. A component failing mid-batch still ends the run:
# the failure is usually in something the later components share (the signing
# key, the release host, the GitHub token), and grinding on would turn one
# clear failure into four. The summary is what changes — the batch now says
# what it skipped instead of leaving it to be noticed.

# batch_begin <comp>... — declare the components this run intends to cut.
batch_begin() {
    BATCH_QUEUE="$*"
    BATCH_DONE=""
    BATCH_CURRENT=""
    BATCH_REPORTED=""
}

# batch_start <comp> — mark <comp> as in flight. If the cut dies now, this is
# the component that failed.
batch_start() { BATCH_CURRENT="$1"; }

# batch_ok <comp> — mark <comp> as fully cut.
batch_ok() {
    BATCH_DONE="${BATCH_DONE} $1"
    BATCH_CURRENT=""
}

# batch_summary — print what succeeded, what failed, and what never ran.
#
# Called from release.sh's EXIT/INT/TERM trap, so it must not disturb the exit
# status: it ends on a plain `return 0` and never calls `exit`, leaving the
# status that triggered the trap in place (batch.test.sh pins this by asserting
# a runner's `exit 3` still surfaces as 3).
#
# A no-op until batch_begin has run, so the pre-flight failures that happen
# long before the component loop do not print an empty summary. Reports once —
# INT and EXIT can both fire for a single interrupt.
batch_summary() {
    local queue="${BATCH_QUEUE:-}"
    [ -n "${queue}" ] || return 0
    [ -z "${BATCH_REPORTED:-}" ] || return 0
    BATCH_REPORTED=1

    local done_list="${BATCH_DONE:-}" current="${BATCH_CURRENT:-}"
    local c never=""
    for c in ${queue}; do
        case " ${done_list} " in *" ${c} "*) continue ;; esac
        [ "${c}" = "${current}" ] && continue
        never="${never} ${c}"
    done

    echo
    echo "── batch summary ──"
    # The accumulators already carry a leading space per entry, which supplies
    # the separator after the label.
    if [ -n "${done_list}" ]; then
        echo "   released:${done_list}"
    else
        echo "   released: (none)"
    fi
    [ -z "${current}" ] || echo "   failed: ${current}"
    [ -z "${never}" ]   || echo "   never ran:${never}"
    if [ -n "${current}" ] || [ -n "${never}" ]; then
        echo "   the cut stopped at the first failure — the components above were NOT cut"
    fi
    return 0
}
