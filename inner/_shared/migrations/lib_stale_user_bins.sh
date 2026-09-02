#!/bin/sh
# _shared/migrations/lib_stale_user_bins.sh — the sweep of the pre-0.2.0
# per-user copies of a component's binaries. SOURCED, never executed.
#
# NOT A RUNG. run.sh walks the LEDGER and this file is not in it; it defines
# functions and nothing else, so sourcing it has no effect on a host. It ships
# inside migrations/ because that is the directory both of its callers can
# already resolve beside themselves:
#
#   * the component's inner/<comp>/install.sh, which sources it and calls
#     remove_stale_user_bins on every install — a fresh install must not need
#     the ladder to be coherent;
#   * migrations/stale_user_bins.sh, the 0.2.0 rung, which is how the sweep
#     reaches a host the installer never ran on. THE UPDATER NEVER RUNS
#     install.sh: it swaps binaries and restarts the daemon. So before the rung
#     existed an updated host kept its stale per-user copies forever (observed
#     on a production node, 2026-08-17: the gateway daemon at
#     v0.2.0.2026.08.17 with ~/.local/bin/burrowee-gateway still on the Aug 8
#     build, and a drift row whose recommended `restart` provably could not
#     clear it).
#
# ONE FILE, because the two callers must not merely agree — every guard below
# fails silently in the safe-looking direction, so a second implementation that
# drifted would look exactly like this one right up to the deletion it got
# wrong. The rung being idempotent is what makes it safe for both to run.
#
# IT IS THE SAME FILE FOR EVERY COMPONENT, TOO. The gateway carries its own copy
# in the gateway repo (it shipped there first, and its runner is the gateway's);
# edge and cli share THIS one, staged into both kits from one source by
# tools/payload.sh. The only thing that varies between components is the list of
# names, which comes from migrations/component.conf.
#
# THE FIVE GUARDS, each of which has a real failure behind it:
#   1. THE OPERATOR'S HOME, NOT $HOME. The documented install is
#      `curl … | sudo sh`, where $HOME is /root or /var/root — a tree no
#      per-user install ever wrote to. A sweep aimed there finds nothing,
#      reports success and leaves every shadowing copy in place. Resolved by
#      lib_paths.sh's operator_home.
#   2. PROVABLY OURS, BY READING AND NEVER EXECUTING. The directory being swept
#      is writable by the very user whose files are in question; running one of
#      them to ask what it is would hand uid 0 to anyone who can drop a file
#      there. The evidence is the Go build stamp, read with grep.
#   3. EXACT NAMES, NEVER A GLOB. $STALE_USER_BINS is the whole candidate set.
#   4. NOTHING IS REMOVED THAT HAS NO ROOT-INSTALLED TWIN. A per-user binary is
#      stale exactly when $BIN_DIR holds a copy of ours under the same name;
#      with no twin it is not a leftover, it is the only install this host has.
#      That is what keeps a live per-user cli alive, and it is what lets the
#      bare `burrowee` dispatcher go without a second, weaker rule.
#   5. NOTHING IS REMOVED WHILE A UNIT STILL NAMES *THAT FILE*. On macOS the
#      KeepAlive.PathState the installers writes keys off the binary's
#      existence, so unlinking it does not stale a future restart — it stops
#      the running daemon. Asked PER FILE: the directory-scoped form of this
#      guard let one edge unit block six gateway names it does not mention
#      (observed 2026-08-18), which is guard-scope failure, not conservatism.
# Undecidable cases fail toward KEEP.
#
# Every variable is defaulted with ${X:-…} so a caller that already resolved one
# keeps its answer. Nothing here runs at source time except these assignments
# and the component.conf load below.

# THE COMPONENT'S OWN FACTS come from migrations/component.conf, beside this
# file in the kit and owned by the component's repo. Loaded only when the
# caller has not already supplied $STALE_USER_BINS, so install.sh (which knows
# its own $BINS) and run.sh (which sourced the conf itself) both stay in
# charge of their own answer.
#
# A missing conf is NOT defaulted to a guessed list. An empty $STALE_USER_BINS
# sweeps nothing and says so at the call sites; a guessed one would delete by a
# name this component may not own.
if [ -z "${STALE_USER_BINS:-}" ]; then
    _lsub_here="${LIB_STALE_USER_BINS_DIR:-$(dirname "$0")}"
    if [ -f "$_lsub_here/component.conf" ]; then
        # shellcheck source=/dev/null
        . "$_lsub_here/component.conf"
    fi
fi
STALE_USER_BINS="${STALE_USER_BINS:-}"

# lib_paths.sh holds home_of_user / operator_home / root_home — one definition
# each, shared with run.sh and with the installers. Sourced only when the
# caller has not already loaded it (install.sh sources both, in order).
if ! command -v operator_home >/dev/null 2>&1; then
    _lsub_paths="${LIB_STALE_USER_BINS_DIR:-$(dirname "$0")}/lib_paths.sh"
    if [ -f "$_lsub_paths" ]; then
        # shellcheck source=lib_paths.sh
        . "$_lsub_paths"
    fi
fi

# The per-user directory a pre-0.2.0 install wrote to. Not a seam anyone should
# set: it is the historical default, and it is what makes the copies shadow
# $BIN_DIR on a normal PATH.
STALE_USER_BIN_SUBDIR="${STALE_USER_BIN_SUBDIR:-.local/bin}"

BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}"
LAUNCHD_DIR="${LAUNCHD_DIR:-${BURROWEE_LAUNCHD_DIR:-/Library/LaunchDaemons}}"
SYSTEMD_DIR="${SYSTEMD_DIR:-${BURROWEE_SYSTEMD_DIR:-/etc/systemd/system}}"

# === SHARED SWEEP CONTRACT BEGIN ===
# Everything between this line and the matching END line is BYTE-IDENTICAL in
# the two repos that carry this library:
#
#   burrowee-git/gateway  migrations/lib_stale_user_bins.sh
#   burrowee-git/release  inner/_shared/migrations/lib_stale_user_bins.sh
#
# They cannot be one file: they are two independent repos, the gateway's ladder
# is assembled wholly from the gateway worktree (tools/payload.sh's
# takes_shared_ladder deliberately excludes it) and the gateway's own suite runs
# the rung out of its own migrations/ directory. So the drift is guarded instead
# of prevented: each repo's suite hashes THIS REGION and compares it against a
# pinned digest that is the same literal in both. Editing one copy reddens that
# repo's test until the digest is updated, and the digest cannot be updated to a
# value the other repo does not also produce without the other repo's test going
# red in turn. Nothing outside the sentinels is compared, which is what lets the
# preamble above differ (the gateway hardcodes its own binary list and defines
# operator_home inline; the shared copy loads component.conf and lib_paths.sh).
#
# The functions below are the WHOLE decision. Anything that changes what gets
# deleted belongs in here.

# LNB_TAB / LNB_CR — the two terminator characters that cannot be written
# legibly inside a `case` pattern. Built once, at source time, and compared as
# values. A CR is in the list because a unit file edited on Windows ends every
# line with one, and without it the last name on every line would look
# unterminated and be spared forever.
LNB_TAB="$(printf '\t')"
LNB_CR="$(printf '\r')"

# ---------------------------------------------------------------------------
# line_names_bin <line> <path> — whether <line> names exactly <path>, with the
# BASENAME TERMINATED.
#
# THE SUBSTRING HAZARD, and it is not hypothetical. A plain `grep -F
# "$dir/burrowee-gateway"` matches a unit whose ExecStart is
# "$dir/burrowee-gateway-updater", so the shorter name would be spared by the
# longer one's unit and the sweep would silently under-remove — the same
# collision family run.sh already records for burrowee-gateway-console.
#
# A match counts only when the character AFTER it TERMINATES the basename: end
# of line, a space, a tab, a CR, a closing quote, or the "<" that ends a launchd
# plist <string>. Anything else is treated as continuing the name, so the "-" of
# "-updater" does not count and the scan moves past it to look for a later
# occurrence on the same line.
#
# The terminator set is written as an ALLOW-LIST rather than as "not a name
# character" so that an unforeseen byte errs toward KEEP. "Not a name character"
# would make every unlisted byte a terminator, i.e. a match, i.e. a DELETE — the
# unrecoverable direction, on the one guard whose whole job is to not delete out
# from under a running daemon.
#
# Written with parameter expansion rather than a regex ON PURPOSE. The needle is
# an absolute path chosen by the host, so it routinely carries "." and may carry
# "+", "(" or "|"; feeding it to grep -E unescaped either loosens the match or
# makes grep exit non-zero, and a grep that ERRORS reads to the caller as "no
# unit names this file" — the unsafe direction, where the sweep deletes.
# ---------------------------------------------------------------------------
line_names_bin() {
    _lnb_l="$1"
    _lnb_n="$2"
    while :; do
        case "$_lnb_l" in
        *"$_lnb_n"*) ;;
        *) return 1 ;;
        esac
        _lnb_l="${_lnb_l#*"$_lnb_n"}"
        [ -n "$_lnb_l" ] || return 0
        _lnb_c="${_lnb_l%"${_lnb_l#?}"}"
        case "$_lnb_c" in
        ' ' | '"' | "'" | '<' | "$LNB_TAB" | "$LNB_CR") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# file_names_bin <file> <path> — whether any line of <file> names <path> with
# the basename terminated.
#
# `read` loses a final line that carries no newline, and a hand-edited unit file
# is exactly where that happens, so the `|| [ -n "$_fnb_l" ]` tail is load-
# bearing rather than idiom.
# ---------------------------------------------------------------------------
file_names_bin() {
    _fnb_f="$1"
    _fnb_n="$2"
    _fnb_l=""
    while IFS= read -r _fnb_l || [ -n "$_fnb_l" ]; do
        if line_names_bin "$_fnb_l" "$_fnb_n"; then return 0; fi
        _fnb_l=""
    done <"$_fnb_f"
    return 1
}

# ---------------------------------------------------------------------------
# unit_naming_bin <dir> <bin> <operator-home> — the first service unit file on
# this host that still names <dir>/<bin>, or empty + non-zero when none does.
#
# GUARD 4, AND THE POINT OF THIS TASK. It used to ask whether any unit named the
# DIRECTORY and, on a single hit, abandon the entire sweep. Observed on a
# production node 2026-08-18: one /etc/systemd/system/burrowee-edge-updater
# .service naming /home/ubuntu/.local/bin blocked all six of the gateway's
# names — names that unit does not mention and never could — so the sweep
# removed nothing, the stale dispatcher survived, and it went on answering every
# `burrowee …` with Aug-8 code. Correct logic, wrong observed set.
#
# The question is now asked PER CANDIDATE FILE: does any unit name THIS file? A
# file no unit names is swept; a file some unit names is left, and the caller's
# message names both the file and the unit.
#
# What is NOT in question is the direction it fails in. It scans the unit FILES
# rather than asking the supervisor and treats a file on disk as "possibly
# loaded", because the two outcomes are "skip a cleanup" and "stop a running
# daemon" and only one of those is recoverable by running again. The system dirs
# cover ANOTHER component's units too, which is the case no single component's
# own re-render can speak for.
#
# grep -F is a pre-filter and never the decision: it cheaply skips the files that
# cannot match, and file_names_bin then decides the ones that can.
# ---------------------------------------------------------------------------
unit_naming_bin() {
    _unb_needle="$1/$2"
    for _unb_d in "$LAUNCHD_DIR" "$SYSTEMD_DIR" \
        "$3/Library/LaunchAgents" "$3/.config/systemd/user"; do
        [ -d "$_unb_d" ] || continue
        for _unb_f in "$_unb_d"/*; do
            [ -f "$_unb_f" ] || continue
            [ -r "$_unb_f" ] || continue
            grep -qF -- "$_unb_needle" "$_unb_f" 2>/dev/null || continue
            if file_names_bin "$_unb_f" "$_unb_needle"; then
                echo "$_unb_f"
                return 0
            fi
        done
    done
    return 1
}

# ---------------------------------------------------------------------------
# is_burrowee_binary <file> — whether <file> is one of OURS, decided by reading
# it and never by running it (guard 2).
#
# Every burrowee binary is a Go binary built from a github.com/burrowee-git/*
# module, and the toolchain stamps that module path into the build-info blob of
# the executable (the same bytes `go version -m` reads back). It survives
# -trimpath and -ldflags "-s -w", so a release build carries it exactly as a
# local one does.
#
# The claim this supports is narrow and that is the point: combined with an
# EXACT name from $STALE_USER_BINS (never a glob) and a regular-file test, a
# file that also carries our module path is ours or vendors us. An operator's
# own script that happens to share the name does not carry it, and is left
# alone.
# ---------------------------------------------------------------------------
is_burrowee_binary() {
    LC_ALL=C grep -qF 'github.com/burrowee-git/' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# stale_bin_verdict <path> — the ownership half of the decision, as one word:
# absent | symlink | irregular | foreign | ours.
# ---------------------------------------------------------------------------
stale_bin_verdict() {
    if [ -h "$1" ]; then echo symlink; return 0; fi
    [ -e "$1" ] || { echo absent; return 0; }
    [ -f "$1" ] || { echo irregular; return 0; }
    if is_burrowee_binary "$1"; then echo ours; else echo foreign; fi
}

# ---------------------------------------------------------------------------
# system_twin_exists <bin> — whether $BIN_DIR holds a copy of OURS under the
# same name.
#
# THIS IS WHAT MAKES A PER-USER COPY "STALE" RATHER THAN "THE INSTALL". A
# per-user binary is stale exactly when the same name has been placed in the
# system bin dir: that copy is the one a normal PATH should have been finding,
# and the per-user one is what shadows it. With no such copy the per-user file
# is not a leftover at all, it is the only install this host has — which is the
# cli's situation until its root collapse lands, and deleting it would uninstall
# a working cli.
#
# It is deliberately NOT a uid-0 test. $BIN_DIR is whatever destination the
# CALLER resolved (an explicit PREFIX installs unprivileged, in full), so
# demanding root ownership here would make the sweep silently do nothing on
# every such host — a guard scoped to the wrong observed set, which is the very
# defect being fixed. Whether $BIN_DIR is fit to be named by a root unit is a
# different question, asked by the root-secure ancestor walk that owns it.
#
# The twin must carry the stamp for the same reason the candidate must: an
# operator's own /usr/local/bin/burrowee wrapper is not evidence that a burrowee
# component was installed there, and treating it as evidence would delete the
# dispatcher every component still needs.
# ---------------------------------------------------------------------------
system_twin_exists() {
    [ -n "${BIN_DIR:-}" ] || return 1
    [ "$(stale_bin_verdict "$BIN_DIR/$1")" = ours ]
}

# ---------------------------------------------------------------------------
# stale_bin_decision <dir> <bin> <operator-home> — the WHOLE decision for one
# candidate, as one word:
#
#   remove      sweep it
#   absent      nothing there
#   symlink     not a binary an installer placed
#   irregular   not a regular file
#   foreign     our exact name, but no burrowee build stamp
#   no-twin     ours, but nothing of that name in $BIN_DIR — the LIVE install
#   unit:<f>    ours and replaced, but <f> still names it
#
# ONE FUNCTION BECAUSE THERE IS ONE DECISION. The remover switches on it to pick
# a message and the --applies probe switches on it to answer at all, so a probe
# that authorised a removal the sweep would then decline — the shape that buys a
# stopped gateway for no work — cannot be written without changing both at once.
#
# Order matters and is cheapest-first: ownership is a stat plus a grep of one
# file, the twin is one more of each, and only a candidate that passes both is
# worth walking every unit file on the host for.
# ---------------------------------------------------------------------------
stale_bin_decision() {
    _sbd_v="$(stale_bin_verdict "$1/$2")"
    case "$_sbd_v" in
    ours) ;;
    *)
        echo "$_sbd_v"
        return 0
        ;;
    esac
    if ! system_twin_exists "$2"; then
        echo no-twin
        return 0
    fi
    if _sbd_u="$(unit_naming_bin "$1" "$2" "$3")"; then
        echo "unit:$_sbd_u"
        return 0
    fi
    echo remove
}

# ---------------------------------------------------------------------------
# remove_one_stale_bin <dir> <bin> <operator-home> — act on one candidate, and
# SAY what was decided. Absent is silent, not a warning: this runs on every
# install, and a host that never had a per-user layout must say nothing at all.
# ---------------------------------------------------------------------------
remove_one_stale_bin() {
    _ros_p="$1/$2"
    _ros_d="$(stale_bin_decision "$1" "$2" "$3")"
    case "$_ros_d" in
    absent) return 0 ;;
    symlink)
        echo "note: $_ros_p is a symlink, not a binary this installer placed — left in place." >&2
        return 0
        ;;
    irregular)
        echo "note: $_ros_p is not a regular file — left in place." >&2
        return 0
        ;;
    foreign)
        echo "note: $_ros_p carries no burrowee build stamp — it is not ours, left in place." >&2
        return 0
        ;;
    no-twin)
        echo "kept $_ros_p — there is no $BIN_DIR/$2 to replace it, so this is the live install, not a stale copy"
        return 0
        ;;
    unit:*)
        echo "note: ${_ros_d#unit:} still names $_ros_p, so a supervisor may be running it —" >&2
        echo "note: left in place. Re-render or remove that unit and run this again." >&2
        return 0
        ;;
    esac
    if rm -f "$_ros_p"; then
        echo "removed stale per-user binary: $_ros_p"
        # The counter the shell hint keys on. Incremented HERE, on the one
        # branch where a path stopped existing — not per candidate and not
        # per run, because every other outcome leaves the operator's shell
        # resolving exactly what it resolved before.
        STALE_BINS_REMOVED=$((${STALE_BINS_REMOVED:-0} + 1))
    else
        echo "note: could not remove $_ros_p — it shadows $BIN_DIR on PATH; remove it by hand." >&2
    fi
}

# ---------------------------------------------------------------------------
# stale_user_bin_dir <operator-home> — the directory to sweep, or empty when
# there is none to consider. Empty covers three cases the callers treat
# identically: no operator home resolved, no per-user bin directory on this
# host, and — the guard that is written rather than argued — a per-user
# directory that IS $BIN_DIR, where sweeping would delete the install this run
# just made.
#
# THAT THIRD CASE IS THE CLI'S NORMAL STATE, not a corner. The cli installs to
# ${PREFIX:-$HOME/.local}/bin by design, so on an ordinary cli host the
# directory to sweep and the install destination are the same directory and
# this returns empty — the cli's rung is a no-op there, correctly. It has
# something to do only on a cli whose $BIN_DIR is somewhere else (an explicit
# PREFIX, e.g. a root-owned /usr/local), where the per-user copies really are
# stale and really do shadow it on PATH.
# ---------------------------------------------------------------------------
stale_user_bin_dir() {
    _subd_home="${1:-}"
    [ -n "$_subd_home" ] || return 0
    _subd_dir="$_subd_home/$STALE_USER_BIN_SUBDIR"
    [ -d "$_subd_dir" ] || return 0
    [ "$_subd_dir" != "$BIN_DIR" ] || return 0
    echo "$_subd_dir"
}

# ---------------------------------------------------------------------------
# stale_user_bins_pending — whether a sweep right now would remove at least one
# file. The rung's --applies probe, and the same decision the sweep makes,
# candidate for candidate.
#
# Silent: a probe is asked speculatively, on hosts where the answer is normally
# "no", and every note it printed would appear on all of them.
# ---------------------------------------------------------------------------
stale_user_bins_pending() {
    [ -n "$STALE_USER_BINS" ] || return 1
    _sbp_home="$(operator_home 2>/dev/null)"
    _sbp_dir="$(stale_user_bin_dir "$_sbp_home")"
    [ -n "$_sbp_dir" ] || return 1
    for _sbp_b in $STALE_USER_BINS; do
        if [ "$(stale_bin_decision "$_sbp_dir" "$_sbp_b" "$_sbp_home" 2>/dev/null)" = remove ]; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# login_shell_of_user <name> — that account's LOGIN SHELL on stdout, or empty
# and non-zero.
#
# FIELD 7 OF THE PASSWD ENTRY, NEVER $SHELL. This runs under
# `curl … | sudo sh`, where $SHELL describes the environment that INVOKED sudo
# — sudo does not reset it, and `sudo -i` or a cron context sets it to root's —
# while the account that will hit a stale command hash is $SUDO_USER. The two
# are routinely different shells, and only the passwd entry answers the
# question actually being asked.
#
# Three sources, each authoritative where the one before it does not exist:
# getent (portable on Linux, and it reads NSS so LDAP/SSS accounts resolve),
# dscl (macOS, which has no getent), and a plain read of /etc/passwd for a slim
# container image that ships neither. The last is a `while read` over the colon
# fields rather than sed or awk: the account name would otherwise be spliced
# into a regex, where a metacharacter in it matches the wrong line or none.
# ---------------------------------------------------------------------------
login_shell_of_user() {
    _lsu=""
    if command -v getent >/dev/null 2>&1; then
        _lsu="$(getent passwd "$1" 2>/dev/null | cut -d: -f7)"
    fi
    if [ -z "$_lsu" ] && command -v dscl >/dev/null 2>&1; then
        _lsu="$(dscl . -read "/Users/$1" UserShell 2>/dev/null | sed -n 's/^UserShell: //p')"
    fi
    if [ -z "$_lsu" ] && [ -r /etc/passwd ]; then
        _lsu="$(while IFS=: read -r _lsu_n _lsu_x _lsu_u _lsu_g _lsu_c _lsu_h _lsu_s; do
            if [ "$_lsu_n" = "$1" ]; then echo "$_lsu_s"; break; fi
        done </etc/passwd)"
    fi
    [ -n "$_lsu" ] || return 1
    echo "$_lsu"
}

# ---------------------------------------------------------------------------
# stale_bin_shell_hint — say that the files just removed are what an
# ALREADY-RUNNING shell may still be pointing at, and name the one command that
# clears it.
#
# THE COST THIS EXISTS TO PAY. Observed on a production node 2026-08-18,
# immediately after the sweep did its job:
#
#   ✓ gateway gateway/v0.2.0.2026.08.18.9cbda158 installed and its 0.2.0 migrations forced
#   $ burrowee gateway doctor
#   -bash: /home/ubuntu/.local/bin/burrowee: No such file or directory
#
# bash caches an executed command's absolute path and re-execs THAT path; the
# operator's shell predated the sweep, so it still held the path of a file that
# had just been removed. `. ~/.bashrc` cleared it only incidentally — bash
# discards the hash table on any PATH assignment. A successful cleanup whose
# next command fails reads as a broken install, and it lands on exactly the
# operator who did the right thing.
#
# IT CANNOT RELOAD THE CALLER'S SHELL AND MUST NOT TRY. The sweep is a child of
# `sudo sh` under `curl … | sudo sh`; a child cannot touch its parent's hash
# table, environment or rc state. Nothing here execs anything, and nothing here
# writes to an rc file — the rc-editing block was deliberately removed for
# root-installed components and must not come back through this door. One
# accurate sentence is the whole deliverable.
#
# WHAT EACH SHELL NEEDS WAS MEASURED, NOT ASSUMED. Each shell was given a
# command in directory A with a second copy in directory B further along PATH,
# ran it, had A's copy removed, and ran it again — interactively, on a pty,
# because that is the operator's situation:
#
#   bash 5.3   re-execs the cached path and fails with "No such file or
#              directory". It does NOT fall back to a re-search. `hash -r`
#              clears it, and this is the reported symptom.
#   zsh 5.9    cache the path too, but were observed to re-search PATH once it
#   dash       has vanished, so they self-heal. They are still told `hash -r`:
#   ash        it is POSIX, valid and harmless in every one of them, and the
#   sh         self-heal is one shell option away from being off.
#   fish 4.0.6 HAS NO `hash` BUILTIN AT ALL — `hash -r` is "Unknown command:
#              hash", exit 127, and `type hash` finds nothing — and it
#              re-resolved the command by itself. So it is told what happened
#              and given NO command: answering a confusing failure with a
#              second confusing failure is worse than saying nothing.
#
# An unrecognised shell — and an account whose passwd entry cannot be read —
# gets the POSIX form plus "open a new shell", which is true of every shell
# there is. It is never a guess about which shell the operator has.
#
# IT CAN NEVER FAIL THE MIGRATION. By the time it runs the binaries are placed
# and the state is migrated; a message is not worth an exit code, so every path
# through it ends at `return 0`.
# ---------------------------------------------------------------------------
stale_bin_shell_hint() {
    _sbsh_shell=""
    case "${SUDO_USER:-}" in
    '' | root) ;;
    *) _sbsh_shell="$(login_shell_of_user "$SUDO_USER" 2>/dev/null || true)" ;;
    esac

    echo "a shell that is ALREADY RUNNING still remembers the removed path in its"
    echo "command-hash table, so its next \`burrowee\` command can fail with \"No such"
    echo "file or directory\". Nothing is broken — only that one shell's cache is stale."
    case "${_sbsh_shell##*/}" in
    bash | zsh | dash | ash | sh)
        echo "clear it in ${_sbsh_shell##*/}: hash -r"
        ;;
    fish)
        echo "your login shell is $_sbsh_shell — fish has no \`hash\` builtin and"
        echo "re-resolves a removed command by itself, so there is nothing to run."
        ;;
    *)
        echo "clear it with \`hash -r\` (bash, zsh, dash, ash) — or just open a new shell."
        ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# remove_stale_user_bins — sweep the per-user copies of THIS component's
# binaries, by exact name, after everything else has converged.
#
# THE BARE `burrowee` DISPATCHER IS NO LONGER A SPECIAL CASE, and that is an
# operator ruling rather than a simplification: once a root dispatcher exists,
# the per-user one is removed, full stop. It used to be spared whenever any
# other stamped burrowee-* file was left in the directory, which is exactly what
# kept the Aug-8 dispatcher alive on a host that also had per-user edge
# binaries — and a surviving per-user `burrowee` shadows $BIN_DIR on PATH and
# answers every `burrowee …` with old code, which is the whole complaint.
#
# Removing it strands nothing: the root dispatcher pins only gateway, edge and
# register to the system bin dir and still resolves every other component
# through PATH and then {/usr/local/bin, /opt/homebrew/bin, ~/.local/bin}, so a
# per-user component it does not pin is still found where it lies. The root-twin
# predicate is what makes this safe to state unconditionally: with no root
# dispatcher there is no twin, and the per-user one stays.
# ---------------------------------------------------------------------------
remove_stale_user_bins() {
    if [ -z "$STALE_USER_BINS" ]; then
        echo "note: no binary list for the stale per-user sweep (migrations/component.conf" >&2
        echo "note: is missing or sets no STALE_USER_BINS) — nothing was swept." >&2
        return 0
    fi
    _rsb_home="$(operator_home)"
    _rsb_dir="$(stale_user_bin_dir "$_rsb_home")"
    [ -n "$_rsb_dir" ] || return 0

    STALE_BINS_REMOVED=0
    for _rsb_b in $STALE_USER_BINS; do
        remove_one_stale_bin "$_rsb_dir" "$_rsb_b" "$_rsb_home"
    done

    # ONLY WHEN A REMOVAL ACTUALLY HAPPENED. A sweep that removed nothing
    # must stay silent: the hint would be false on that host — no path went
    # away — and an operator who sees it on every converged run stops
    # reading it on the one run where it is true. This is also every run of
    # install.sh on an already-clean host, which is most of them.
    if [ "${STALE_BINS_REMOVED:-0}" -gt 0 ]; then
        stale_bin_shell_hint
    fi
    # The sweep's callers run under `set -e` and this is the last thing they
    # call; an advisory message must not be able to end a migration.
    return 0
}
# === SHARED SWEEP CONTRACT END ===

# ---------------------------------------------------------------------------
# THE STALE EXEC ROOT — /usr/local/bin's REAL copies of this component's
# binaries, left behind when 0.3 moved the exec root to /usr/local/burrowee/bin.
#
# OUTSIDE THE CONTRACT REGION ABOVE, deliberately: this sweep exists only on
# the shared ladder (edge, relay), and the gateway's copy of this library — the
# other half of the byte-pinned region — sweeps its own exec root from its own
# repo. It REUSES the region's decisions (stale_bin_verdict, system_twin_exists,
# unit_naming_bin) rather than restating them, so what "ours", "has a twin" and
# "still named by a unit" mean cannot drift between the two sweeps.
#
# WHAT IT DOES NOT TOUCH, per item, and why:
#   * A SYMLINK, ours or anyone's. The 0.3 installer links the operator-typed
#     names from /usr/local/bin into the new tree (spec §6.1); deleting one of
#     those is deleting the install's PATH entry. Checked FIRST, before
#     ownership, because a link's stamp is its target's.
#   * A file that is not a burrowee binary (no build stamp) — an operator's own.
#   * A name whose twin in $BIN_DIR is missing, not ours, not a regular file
#     owned by $STALE_EXEC_ROOT_TWIN_OWNER, or group/other-writable: the new
#     tree is asserted root-secure by the installer before this ladder runs,
#     and this re-checks the one file it is about to leave as the only copy.
#     The owner is a SEAM (default root) rather than a euid test, so a suite
#     that cannot create root-owned files can still drive both directions.
#   * A file some unit on this host still names. On macOS KeepAlive.PathState
#     keys off the file's existence, so unlinking it stops a running daemon.
#     This is why the rung's sweep is usually a no-op on the FIRST 0.3 run —
#     the 0.2 units still name /usr/local/bin — and why the installers call
#     this again after they have re-rendered the units to the new tree.
# ---------------------------------------------------------------------------
LEGACY_BIN_DIR="${LEGACY_BIN_DIR:-/usr/local/bin}"

# STALE_EXEC_ROOT_KEEP — names the sweep must leave in $LEGACY_BIN_DIR no matter
# what it decides about them. The installer sets it to the operator-typed names
# it did NOT link: on a host whose /usr/local/bin is not root-secure,
# link_operator_bins creates nothing and prints the PATH line instead, and the
# real 0.2 file at that name is then the ONLY copy anything reaches by the
# absolute path — the shared `burrowee` dispatcher above all, which every
# co-installed component and every consumer resolves as /usr/local/bin/burrowee.
# Removing it there would leave that path empty on exactly the host class this
# whole change exists for. Empty on a host where the links WERE made: the link
# replaced the file, so nothing is stranded.
STALE_EXEC_ROOT_KEEP="${STALE_EXEC_ROOT_KEEP:-}"

# stale_exec_root_is_kept NAME — true when NAME is in $STALE_EXEC_ROOT_KEEP.
# stale_exec_root_same_dir A B — true when A and B name the same directory,
# compared after collapsing repeated slashes and stripping trailing ones. The
# rung this sweep replaced normalized both sides for a reason: a seam spelled
# with a trailing slash on one side only makes a raw compare answer "different",
# and the sweep then runs against the INSTALL DESTINATION and deletes the
# binaries the installer just placed.
#
# Deliberately NOT named normalize_dir: inner/*/install.sh defines one and
# sources this library from inside a function, so a second definition of that
# name would silently take over for the rest of that shell.
stale_exec_root_same_dir() {
    _sersd_a="$(printf '%s' "$1" | sed -e 's|//*|/|g' -e 's|/*$||')"
    _sersd_b="$(printf '%s' "$2" | sed -e 's|//*|/|g' -e 's|/*$||')"
    [ "${_sersd_a:-/}" = "${_sersd_b:-/}" ]
}

stale_exec_root_is_kept() {
    for _serik in $STALE_EXEC_ROOT_KEEP; do
        [ "$_serik" = "$1" ] && return 0
    done
    return 1
}
STALE_EXEC_ROOT_TWIN_OWNER="${STALE_EXEC_ROOT_TWIN_OWNER:-root}"

# stale_exec_root_twin_ok <bin> — $BIN_DIR/<bin> is a regular file owned by
# $STALE_EXEC_ROOT_TWIN_OWNER and writable by nobody else. `find -prune` on
# the file itself prints it iff every test holds; POSIX find, both dialects.
stale_exec_root_twin_ok() {
    [ -n "$(find "$BIN_DIR/$1" -prune -type f -user "$STALE_EXEC_ROOT_TWIN_OWNER" ! -perm -g+w ! -perm -o+w 2>/dev/null)" ]
}

# stale_exec_root_decision <bin> <operator-home> — the WHOLE decision for one
# name at $LEGACY_BIN_DIR, as one word: symlink | absent | irregular | foreign
# | no-twin | twin-untrusted | unit:<file> | remove. One function, used by
# the probe and the sweep alike, for the reason stale_bin_decision gives.
stale_exec_root_decision() {
    _serd_p="$LEGACY_BIN_DIR/$1"
    # stale_bin_verdict answers `symlink` FIRST, before ownership — a link's
    # stamp is its target's — which is exactly the order this sweep needs.
    _serd_v="$(stale_bin_verdict "$_serd_p")"
    case "$_serd_v" in
    ours) ;;
    *) echo "$_serd_v"; return 0 ;;
    esac
    system_twin_exists "$1" || { echo no-twin; return 0; }
    stale_exec_root_twin_ok "$1" || { echo twin-untrusted; return 0; }
    if _serd_u="$(unit_naming_bin "$LEGACY_BIN_DIR" "$1" "$2")"; then
        echo "unit:$_serd_u"
        return 0
    fi
    echo remove
}

# stale_exec_root_bins_pending — whether a sweep right now would remove at
# least one file: the rung's --applies probe. FAILS OPEN: a legacy directory
# this process cannot read is "still needed", never "nothing there" — a wrong
# yes costs one no-op run, a wrong no strands the copies forever.
stale_exec_root_bins_pending() {
    [ -n "$STALE_USER_BINS" ] || return 1
    [ -d "$LEGACY_BIN_DIR" ] || return 1
    ! stale_exec_root_same_dir "$LEGACY_BIN_DIR" "$BIN_DIR" || return 1
    _serp_dir="$LEGACY_BIN_DIR"
    [ -r "$_serp_dir" ] && [ -x "$_serp_dir" ] || return 0
    _serp_home="$(operator_home 2>/dev/null)"
    for _serp_b in $STALE_USER_BINS; do
        stale_exec_root_is_kept "$_serp_b" && continue
        if [ "$(stale_exec_root_decision "$_serp_b" "$_serp_home" 2>/dev/null)" = remove ]; then
            return 0
        fi
    done
    return 1
}

# remove_stale_exec_root_bins — sweep $LEGACY_BIN_DIR, by exact name, per
# item, saying what was decided about every name that was there. Silent for
# an absent name, and never fatal.
remove_stale_exec_root_bins() {
    if [ -z "$STALE_USER_BINS" ]; then
        echo "note: no binary list for the stale exec-root sweep (migrations/component.conf" >&2
        echo "note: is missing or sets no STALE_USER_BINS) — nothing was swept." >&2
        return 0
    fi
    [ -d "$LEGACY_BIN_DIR" ] || return 0
    # Never the install destination itself — a host whose exec root never
    # moved, or a seam pointing both at one directory. Normalized: a trailing
    # slash on one side only would make this compare "different" and sweep the
    # install away.
    ! stale_exec_root_same_dir "$LEGACY_BIN_DIR" "$BIN_DIR" || return 0
    if ! { [ -r "$LEGACY_BIN_DIR" ] && [ -x "$LEGACY_BIN_DIR" ]; }; then
        echo "note: cannot read $LEGACY_BIN_DIR — its stale burrowee copies were not swept." >&2
        return 0
    fi
    _rser_home="$(operator_home 2>/dev/null)"
    for _rser_b in $STALE_USER_BINS; do
        _rser_p="$LEGACY_BIN_DIR/$_rser_b"
        if stale_exec_root_is_kept "$_rser_b"; then
            [ -e "$_rser_p" ] && echo "kept $_rser_p — no link was made at that name, so this is the only copy anything reaches there"
            continue
        fi
        _rser_d="$(stale_exec_root_decision "$_rser_b" "$_rser_home")"
        case "$_rser_d" in
        absent) ;;
        symlink)
            echo "kept $_rser_p — a symlink (the install's PATH entry when it points into $BIN_DIR), never swept"
            ;;
        irregular)
            echo "note: $_rser_p is not a regular file — left in place." >&2
            ;;
        foreign)
            echo "note: $_rser_p carries no burrowee build stamp — it is not ours, left in place." >&2
            ;;
        no-twin)
            echo "kept $_rser_p — there is no $BIN_DIR/$_rser_b to replace it, so this is the live install, not a stale copy"
            ;;
        twin-untrusted)
            echo "note: $BIN_DIR/$_rser_b is not a regular file owned by $STALE_EXEC_ROOT_TWIN_OWNER and writable by nobody" >&2
            echo "note: else — refusing to remove $_rser_p and leave that as the only copy." >&2
            ;;
        unit:*)
            echo "note: ${_rser_d#unit:} still names $_rser_p, so a supervisor may be running it —" >&2
            echo "note: left in place. Once the units name $BIN_DIR, the next install sweeps it." >&2
            ;;
        remove)
            if rm -f "$_rser_p"; then
                echo "removed stale 0.2 exec-root copy: $_rser_p (the install is $BIN_DIR/$_rser_b)"
            else
                echo "note: could not remove $_rser_p — remove it by hand." >&2
            fi
            ;;
        esac
    done
    return 0
}
