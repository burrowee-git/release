#!/bin/bash
# release.command — run this repo's release cut in a DESKTOP session.
#
# Not a release step. It launches tools/release.sh unmodified; every decision
# about what a cut does still lives there. This exists for one reason:
#
#   Signing and notarizing are different capabilities. rcodesign is pure
#   userspace and signs in any session. notarytool reaches Apple through
#   CFNetwork/AppSSO, which needs a per-user bootstrap namespace — in a
#   background/daemon-hosted shell it does not crash politely, it SIGTRAPs with
#   no submission id, and release.sh can only report `status: unknown`. That
#   reads like a vendor outage and is not one.
#
# LaunchServices opens a .command in the desktop's own terminal, which IS such a
# session — no Apple Events, no TCC prompt, no sudo. Hence the extension: this
# file must be openable, not merely executable.
#
#   open tools/release.command        # committed 100755; no chmod needed
#
# Inputs live OUTSIDE this repo or are ignored by it. This file carries flow and
# the names of its own inputs — never a host, credential, absolute machine path,
# or component inventory:
#
#   ~/.agents/local/release.env  machine facts: PATH to the toolchain, signing and
#                             notarization backends, non-interactive flags.
#                             Override with RELEASE_ENV.
#   .release-request          what to cut, written per run. Override with
#                             RELEASE_REQUEST. Sourced as shell. Shape:
#                                 COMPONENTS="edge cli"
#                                 FLAGS="--public"
#
# Output: .release.log, ending in RELEASE-EXIT:<code> so a watcher can block on it
# rather than guess when the run finished. Exactly one run per log — the previous
# run is rotated to .release.log.prev, so a refusal never destroys the record of
# the last real cut. Override the log with RELEASE_LOG.
#
# On a clean finish the launcher also closes the Terminal window it was opened
# into — see close_own_window below, and KEEP_WINDOW=1 to switch that off.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$REPO_ROOT" || exit 1

# The rest of tools/ calls git by absolute path: the per-directory PATH hook on
# this tree strips Homebrew, and release.env rewrites PATH further down. A guard
# that silently loses its git is a guard that passes.
GIT=/usr/bin/git

LOG="${RELEASE_LOG:-$REPO_ROOT/.release.log}"
[ -e "$LOG" ] && mv -f "$LOG" "${LOG}.prev" 2>/dev/null
if ! : > "$LOG"; then
    echo "✗ cannot write log: $LOG" >&2
    exit 1
fi

say() { echo "$@" | tee -a "$LOG"; }
die() { say "✗ $*"; exit 1; }

# close_own_window — dismiss the Terminal window this run was opened into, once
# the run has finished cleanly. Called from the EXIT trap and nowhere else; it
# reads nothing the cut depends on and changes nothing about what a cut does.
#
# Terminal can do this from a profile ("close if the shell exited cleanly"), but
# a profile is a machine-local preference: it does not travel with the repo, and
# the next machine to open this file has not set it. Asking for the close here
# makes the behaviour a property of the launcher.
#
# Three rules, in order of importance:
#
#   1. ONLY on exit 0. A cut that fails and then vanishes is strictly worse than
#      one that fails loudly — the operator has to be able to read which
#      component published and which did not. Every non-zero exit leaves the
#      window up, and the caller enforces that, not this function.
#   2. ONLY this window. `front window` and `every window` are both wrong: the
#      operator may have other Terminal windows open, running unrelated work.
#      The match is this process's own tty(1) — one tty per LIVE window —
#      against the tty of each window's selected tab, and the close only happens
#      when that selects EXACTLY ONE window that is EXACTLY ONE tab and is still
#      running something. Zero matches (not under Terminal at all), several, or a
#      window shared with other tabs (someone's `open` preference made this a tab
#      beside real work) all leave every window alone. A count is not an
#      identity; the tty is — but only among live tabs. A window left behind at
#      "[Process completed]" keeps reporting the tty it used to own, and the
#      kernel hands that same pty to the next window opened, so tty alone can
#      name two windows at once. `busy` is what tells them apart: the dead one is
#      idle, this one is running this script. Without that test the launcher
#      would either close a stranger's window or, having found two, decline to
#      close its own — measured, both.
#   3. NEVER at the cost of the exit status, and NEVER at the cost of finishing.
#      Missing osascript, Terminal not running, a Terminal that does not answer,
#      Apple Events held up by a consent dialog — all discarded, and all bounded.
#      An Apple Event to an app that TCC has not cleared does not fail, it BLOCKS
#      on a dialog; unattended, that would park the launcher after a successful
#      cut with everything already published, waiting on a prompt nobody is
#      watching. So the call runs as a child under a two-second deadline and is
#      killed if it overruns. A window that fails to close is cosmetic; a
#      published release reported as a failure, or one that never reports at all,
#      is not.
#
#      In practice the event should not need a grant: osascript here is hosted by
#      Terminal and its target IS Terminal, and an app scripting itself is exempt
#      — measured on this machine, the close ran with no dialog and left no
#      Automation entry behind. The deadline is for the machine where that does
#      not hold. It cannot be probed for cheaply without risking the very prompt
#      it would be probing for, so the launcher does not try; it just refuses to
#      wait. See .release-request.example if a machine ever does ask.
#
# The sentinel is written BEFORE this runs, so .release.log is complete and
# flushed on disk whatever happens here. Terminal performs the close
# asynchronously and will not act on it while the tab still has a process in it
# — which is this process, for another few milliseconds — so nothing may be
# sequenced after this call and no part of the run may depend on it.
close_own_window() {
    [ "${KEEP_WINDOW:-0}" = "0" ] || return 0
    [ "${TERM_PROGRAM:-}" = "Apple_Terminal" ] || return 0
    [ -x /usr/bin/osascript ] || return 0
    local mytty
    mytty="$(/usr/bin/tty 2>/dev/null)" || return 0
    case "${mytty}" in /dev/tty*) ;; *) return 0 ;; esac
    /usr/bin/osascript \
        -e 'on run argv' \
        -e '  set want to item 1 of argv' \
        -e '  if application "Terminal" is not running then return' \
        -e '  tell application "Terminal"' \
        -e '    set hits to {}' \
        -e '    repeat with w in windows' \
        -e '      try' \
        -e '        if (tty of selected tab of w) is want and (busy of selected tab of w) and (count of tabs of w) is 1 then' \
        -e '          set end of hits to (id of w)' \
        -e '        end if' \
        -e '      end try' \
        -e '    end repeat' \
        -e '    if (count of hits) is 1 then close (window id (item 1 of hits))' \
        -e '  end tell' \
        -e 'end run' \
        "${mytty}" >/dev/null 2>&1 &
    local pid=$! waited=0 state=""
    # The deadline. Polled through ps rather than `kill -0` because a finished
    # child is a zombie until it is waited for, and `kill -0` cannot tell a
    # zombie from a process still sitting on a consent dialog — it would burn the
    # whole two seconds on every successful close.
    while :; do
        state="$(ps -o state= -p "${pid}" 2>/dev/null | tr -d '[:space:]')"
        case "${state}" in
            ""|Z*) break ;;
        esac
        if [ "${waited}" -ge 20 ]; then
            kill -TERM "${pid}" 2>/dev/null
            break
        fi
        /bin/sleep 0.1
        waited=$((waited + 1))
    done
    wait "${pid}" 2>/dev/null
    return 0
}

# ONE emitter for the sentinel. Hand-written sentinels covered only the paths
# someone remembered: closing the Terminal window (SIGHUP — the expected way an
# operator abandons a .command), Ctrl-C, and `set -u` tripping inside a sourced
# file all left a watcher blocked forever.
LOCK=""
on_exit() {
    rc=$?
    trap - EXIT
    [ -n "$LOCK" ] && rmdir "$LOCK" 2>/dev/null
    say "RELEASE-EXIT:${rc}"
    # Last, and only on success: the sentinel above is the final line of the log
    # in every case, and a failed run keeps its window so it can be read.
    [ "$rc" -eq 0 ] && close_own_window
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# 1. Session. Checked FIRST and refused loudly: the whole point of this file is
#    that the wrong session builds and signs for minutes before dying at notarize.
#
#    managername alone is necessary, not sufficient. A daemon shell that re-execs
#    through `launchctl asuser <uid>` lands in the user's GUI domain and reports
#    Aqua while still lacking the console security session AppSSO needs, and a
#    sudo'd run inherits Aqua but notarizes against root's keychain. Each
#    condition refuses separately so the operator learns which one it was.
DOMAIN="$(launchctl managername 2>/dev/null || echo unknown)"
say "session-domain: ${DOMAIN}"
[ "${DOMAIN}" = "Aqua" ] || die "not a desktop session (need Aqua, got ${DOMAIN}) — 'open' this file, do not run it from a shell"
[ "$(id -u)" -ne 0 ] || die "running as root — notarization would use root's keychain; open this file as your own user"
[ -z "${SSH_CONNECTION:-}" ] || die "this is an SSH session — it has no console security session; open this file on the desktop"
[ -t 0 ] || die "stdin is not a terminal — this was not opened by LaunchServices"

# 2. One release at a time. Two `open`s (an agent racing an operator, or a
#    double-click) would otherwise interleave into one log and race each other's
#    marker commits and pushes.
LOCK_DIR="$REPO_ROOT/.release.lock"
mkdir "$LOCK_DIR" 2>/dev/null || die "a release is already running (lock: $LOCK_DIR) — remove it only if no cut is live"
LOCK="$LOCK_DIR"

# 3. Environment. Loaded, never embedded. Restore IFS afterwards: everything
#    below splits COMPONENTS and FLAGS on whitespace, and a sourced file that
#    leaves IFS changed would silently re-split them.
ENV_FILE="${RELEASE_ENV:-$HOME/.agents/local/release.env}"
[ -r "${ENV_FILE}" ] || die "env file not readable: ${ENV_FILE}"
# shellcheck source=/dev/null
. "${ENV_FILE}"
IFS=$' \t\n'
say "env: ${ENV_FILE}"

# 4. Request.
REQUEST="${RELEASE_REQUEST:-$REPO_ROOT/.release-request}"
[ -r "${REQUEST}" ] || die "request file not readable: ${REQUEST}"
COMPONENTS=""; FLAGS=""
# shellcheck source=/dev/null
. "${REQUEST}"
IFS=$' \t\n'
[ -n "${COMPONENTS}" ] || die "request names no COMPONENTS: ${REQUEST}"

# `all` is a real release.sh argument, and it defeats this file: it cuts every
# component inside ONE process with no pushes between, then HEAD reads
# [RELEASED: <last>] and the marker test below can never match `all`. The run
# would report success sitting on four unpushed markers — the exact wedge this
# file exists to prevent. Reject it here rather than discover it afterwards.
set -f   # COMPONENTS/FLAGS are split on whitespace below; they must not glob
for comp in ${COMPONENTS}; do
    case "${comp}" in
        cli|gateway|edge|agent|relay) ;;
        all) die "COMPONENTS=\"all\" is not usable here: it cuts every component in one process with no push between, and leaves markers unpushed. List them instead: COMPONENTS=\"cli gateway edge agent\"" ;;
        *)   die "unknown component: ${comp} (expected cli, gateway, edge, agent or relay)" ;;
    esac
done
say "request: ${COMPONENTS} [${FLAGS}]"

# Said out loud, and said here rather than at exit: the window is gone by the
# time an operator would look for it, so the log has to carry why it went and
# what to set to keep the next one. KEEP_WINDOW may come from the environment or
# from the request file, which has just been sourced.
if [ "${KEEP_WINDOW:-0}" = "0" ]; then
    say "window: closes on a clean finish — set KEEP_WINDOW=1 to keep it open"
else
    say "window: KEEP_WINDOW=${KEEP_WINDOW} — staying open whatever happens"
fi

# A dry run makes no marker commit, so HEAD is still the PREVIOUS marker and the
# subject test below would match it and push whatever is unpushed. Skip the push
# path entirely rather than rely on the marker test to notice.
DRY=0
case " ${FLAGS} " in *" --dry-run "*) DRY=1 ;; esac
[ "$DRY" -eq 0 ] || say "note: --dry-run — components will be cut, no marker will be pushed"

# tree_state — echoes porcelain output, non-zero if git itself failed.
#
# The old `[ -n "$(git status --porcelain)" ]` failed OPEN: git's errors go to
# stderr and stdout is left empty, so a missing git, a held index.lock or an
# unreadable object store all read as "tree is clean" and the push proceeded.
# --untracked-files=all for the reason release_origin.sh gives: a repo-local
# status.showUntrackedFiles=no would otherwise retire the untracked half.
tree_state() { $GIT status --porcelain --untracked-files=all; }

# unpushed_count — commits on HEAD that origin/main does not have. Fetches
# first: the origin guard ran before a multi-minute cut, and nothing else
# re-verifies in-sync at the moment of the push.
unpushed_count() {
    $GIT fetch --quiet origin main || return 1
    $GIT rev-list --count FETCH_HEAD..HEAD
}

# push_marker <comp> — publish exactly the marker this component just wrote.
#
# `git push origin HEAD` published HEAD's whole unpushed ancestry to whatever
# branch HEAD was on, narrowed only by HEAD's subject and a clean tree. Branch,
# detachment and ahead-count were delegated to release.sh's origin guard, which
# is downgraded to report-only under --dry-run. Assert them here, at the moment
# of the push, and name the destination explicitly.
push_marker() {
    local comp="$1" branch ahead
    branch="$($GIT symbolic-ref --quiet --short HEAD)" \
        || die "HEAD is detached — refusing to push"
    [ "${branch}" = "main" ] \
        || die "on branch '${branch}', not main — refusing to push"
    ahead="$(unpushed_count)" \
        || die "cannot reach origin to verify what would be pushed"
    [ "${ahead}" = "1" ] \
        || die "expected exactly 1 unpushed commit (the ${comp} marker), found ${ahead} — inspect before pushing"
    $GIT push origin HEAD:refs/heads/main 2>&1 | tee -a "$LOG"
    [ "${PIPESTATUS[0]}" -eq 0 ] || die "marker push failed for ${comp}"
    say "✓ ${comp} marker pushed"
}

# 5. Cut each component, pushing its marker before the next one starts.
#
#    release.sh deliberately never pushes, and its origin guard refuses to cut
#    while this repo is ahead of its remote. Both are correct on their own and
#    together they strand a batch: component #1 publishes, leaves a marker commit
#    unpushed, and component #2 aborts on the guard. Pushing here is what lets a
#    batch run unattended.
for comp in ${COMPONENTS}; do
    say ""
    say "── cut: ${comp} ──"
    # shellcheck disable=SC2086
    bash tools/release.sh "${comp}" ${FLAGS} 2>&1 | tee -a "$LOG"
    rc="${PIPESTATUS[0]}"
    [ "${rc}" -eq 0 ] || { say "✗ ${comp} failed (exit ${rc}) — later components NOT cut"; say "   already-cut components above are PUBLISHED: drop them from COMPONENTS before re-running"; exit "${rc}"; }

    [ "$DRY" -eq 0 ] || { say "→ ${comp}: --dry-run, nothing to push"; continue; }

    state="$(tree_state)" || die "cannot read git status — refusing to push (is git reachable on PATH set by ${ENV_FILE}?)"
    [ -z "${state}" ] || die "${comp} cut left an unclean tree — refusing to push; inspect before continuing"

    subject="$($GIT log -1 --format=%s)" || die "cannot read HEAD subject — refusing to push"
    case "${subject}" in
        "[RELEASED: ${comp}]"*)
            push_marker "${comp}"
            ;;
        *)
            # One legitimate reason HEAD is not a marker: a re-cut at an
            # identical stamp produces a byte-identical tree, marker_commit()
            # records nothing, and the repo is left IN SYNC (RUNBOOK, "Residual
            # 3"). That is the only shape allowed to pass silently. Anything
            # unpushed here means the cut published something it did not record
            # — which used to print "nothing to push" and exit 0.
            ahead="$(unpushed_count)" \
                || die "cannot reach origin to check for unpushed work after ${comp}"
            if [ "${ahead}" = "0" ]; then
                say "→ ${comp}: no marker and nothing unpushed — re-cut at an identical stamp; the marker for it is already in history"
            else
                die "${comp}: HEAD is not a [RELEASED: ${comp}] marker (got: ${subject}) yet ${ahead} commit(s) are unpushed — the cut published something it did not record; inspect before continuing"
            fi
            ;;
    esac
done

say ""
exit 0
