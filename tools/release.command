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
#   ~/Library/Preferences/com.apple.Terminal.plist
#                             read, never written: which profile a new window
#                             opens with, and whether that profile closes the
#                             window when the shell exits. Override the path with
#                             RELEASE_TERMINAL_PREFS.
#
# The window closes on a clean cut because the SHELL EXITS CLEANLY and Terminal's
# profile acts on it — see window_note below. Nothing here scripts Terminal;
# KEEP_WINDOW=1 holds the window instead.
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

# hold_window — keep this window on screen after a run that would otherwise take
# it away. The only lever a script has over that is not finishing: the window
# goes when the shell exits, so to keep it the shell has to still be here.
#
# Runs AFTER the sentinel, deliberately. .release.log is complete and flushed
# before this blocks, so a watching agent session reads RELEASE-EXIT: and moves
# on while the operator still has the scrollback in front of them. It prints to
# the terminal only — never through say() — because the sentinel is the last line
# of the log and nothing may be written past it.
#
# `read` returns non-zero at EOF, which is what makes this safe when stdin is not
# a person: it falls through instead of hanging forever.
hold_window() {
    [ -t 0 ] || return 0
    printf '\n── %s — press Return to let this window close ──\n' "$1"
    read -r _
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
    # Last, and after the sentinel: the log is finished and on disk before this
    # can block, so holding the window never holds up whoever is reading the log.
    #
    # The second branch is the one that matters. A profile set to "Close the
    # window" closes it on a FAILED cut too — measured, not assumed — and a cut
    # that fails and then disappears off the screen is the worst thing this
    # launcher can do. When that is the setting and the cut failed, the run holds
    # the window whether or not anyone asked for it. Nothing to hold when the
    # profile was unreadable or would have kept the window anyway.
    if [ "${KEEP_WINDOW:-0}" != "0" ]; then
        hold_window "KEEP_WINDOW=${KEEP_WINDOW}"
    elif [ "$rc" -ne 0 ] && [ "${WINDOW_CLOSES_REGARDLESS}" = "1" ]; then
        hold_window "this cut FAILED (exit ${rc}) and your Terminal profile would close the window on it"
    fi
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# 0. What happens to this window afterwards. A note, never a gate: a Terminal
#     preference has no business failing a release. It runs BEFORE the session
#     guard so that the guard's own refusals are covered by it too.
#
#     There is no scripted close here and there deliberately never was. The first
#     attempt asked Terminal to close the window over an Apple Event and it made
#     things WORSE: sent from inside the running .command it left the window
#     pinned open — Terminal will not close a window whose tab still holds a
#     process, and that process is this script — and a window asked once then
#     stopped closing by any route, including the shell-exit setting that had
#     been working. Measured against a control that only exited 0 and closed in
#     under five seconds every time. So the launcher exits cleanly, which is the
#     thing that actually works, and reads the preference to say what that will
#     mean. No Apple Events, nothing for TCC to gate.
#
#     Which profile: `Default Window Settings` is Terminal ▸ Settings ▸ General ▸
#     "New windows open with", and a .command opened by LaunchServices IS a new
#     window; `Startup Window Settings` is the separate "On startup, open" popup,
#     used only for the window Terminal makes when it launches. Default is read
#     first, Startup stands in when Default is absent, and Terminal's own
#     fallback when neither is set is the Basic profile.
#
#     shellExitAction — the tag behind Terminal ▸ Settings ▸ Profiles ▸ Shell ▸
#     "When the shell exits". MEASURED on this machine, because the numbers are
#     menu tags and not the menu order, and guessing them the obvious way gets
#     them backwards:
#
#       1  closes the window HOWEVER the run ended. A .command exiting 0 and one
#          exiting 3 both had their window closed. This is the dangerous one: it
#          takes a failed cut off the screen, so the trap holds the window itself
#          when a run fails under it.
#       2  never closes the window. A shell that exited 0 under it stayed.
#       absent  Terminal's default, which is also to leave the window open.
#       anything else  NOT determined here. "Close if the shell exited cleanly"
#          exists in the menu but no profile on the machine used it, so its tag
#          was never observed and this file will not invent one — an unknown
#          value is reported as unknown rather than guessed into a branch.
TERMINAL_PREFS="${RELEASE_TERMINAL_PREFS:-$HOME/Library/Preferences/com.apple.Terminal.plist}"
PLIST=/usr/libexec/PlistBuddy

# Set by window_note when the profile will close this window even on a failure,
# which is what the EXIT trap needs to know. Default 0: unreadable prefs, another
# terminal, or a setting that keeps the window all mean "nothing to hold".
WINDOW_CLOSES_REGARDLESS=0

# plist_get <path> — one value out of the prefs, empty if it is not there. Keys
# are quoted because every one of them has spaces in it and PlistBuddy splits a
# path on them. Read only: this file must never write the operator's settings.
plist_get() { "$PLIST" -c "Print :$1" "${TERMINAL_PREFS}" 2>/dev/null; }

window_note() {
    [ "${TERM_PROGRAM:-}" = "Apple_Terminal" ] || return 0
    [ -x "$PLIST" ] || return 0
    [ -r "${TERMINAL_PREFS}" ] || return 0
    local profile action where
    profile="$(plist_get '"Default Window Settings"')"
    [ -n "${profile}" ] || profile="$(plist_get '"Startup Window Settings"')"
    [ -n "${profile}" ] || profile="Basic"
    action="$(plist_get "\"Window Settings\":\"${profile}\":shellExitAction")"
    where="Terminal ▸ Settings ▸ Profiles ▸ ${profile} ▸ Shell ▸ \"When the shell exits\""
    case "${action}" in
        1)  WINDOW_CLOSES_REGARDLESS=1
            say "note: Terminal profile '${profile}' closes this window however the cut ends — a FAILED cut would vanish off the screen, so this run will hold the window itself if it fails. To stop that being necessary: ${where}" ;;
        2)  say "note: Terminal profile '${profile}' never closes this window — close it yourself when the cut is done (${where})" ;;
        "") say "note: Terminal profile '${profile}' has no \"When the shell exits\" setting, so Terminal will leave this window open — close it yourself, or set it in ${where}" ;;
        *)  say "note: Terminal profile '${profile}' has \"When the shell exits\" set to something this launcher has not measured (shellExitAction=${action}); check what it does with a failed cut before trusting this window to stay (${where})" ;;
    esac
}
window_note

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

# Said out loud, and said here rather than at exit: the window may be gone by the
# time an operator would look for it, so the log has to carry what was decided
# and how to decide otherwise. KEEP_WINDOW may come from the environment or from
# the request file, which has just been sourced.
if [ "${KEEP_WINDOW:-0}" = "0" ]; then
    say "window: closing is your Terminal profile's business — KEEP_WINDOW=1 holds it open regardless"
else
    say "window: KEEP_WINDOW=${KEEP_WINDOW} — held at the end until you press Return"
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
