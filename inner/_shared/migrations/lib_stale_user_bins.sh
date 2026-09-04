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

# --- LINK OWNERSHIP · BYTE-IDENTICAL COPY · do not edit one copy -------------
# This block exists three times in the release repo — in
# _shared/migrations/lib_stale_user_bins.sh (inside the SHARED SWEEP CONTRACT
# region, so it travels to the gateway repo's copy of that library too) and in
# inner/gateway/install.sh and inner/edge/install.sh beside
# unlink_operator_bins. The sweep and the uninstall must not disagree about
# which links are ours, and the uninstall path cannot depend on the library
# being loaded: the gateway sources it lazily, from inside its sweep functions.
# The copies are pinned byte-identical by TestLinkOwnershipCopiesAreIdentical,
# the same way the PREFIX gate's four copies are pinned by
# tools/prefix-gate-drift.test.sh.
#
# link_target_is_ours <link-path> — whether <link-path> is a symlink this
# project placed: one whose target names a file DIRECTLY inside $BIN_DIR.
#
# IT USED TO BE A PREFIX MATCH — `case "$(readlink "$p")" in "$BIN_DIR"/*)` —
# and that accepted a shape no install ever created: a target of
# "$BIN_DIR/../../etc/foo" begins with "$BIN_DIR/" and so read as ours, and a
# foreign link at a burrowee-typed name was removed on that evidence. The blast
# radius was bounded — removing a symlink unlinks the LINK and never its
# target, and the name has to be in the candidate list already — so this was a
# false-positive removal rather than a traversal write. It was still a decision
# made on a string that did not mean what the comparison assumed.
#
# WHAT THE PREFIX FORM DID GET RIGHT, so nobody "fixes" it back the other way:
# a SIBLING directory was never a hole. The pattern carries an explicit "/"
# after $BIN_DIR, so "$BIN_DIR-old/burrowee" did not match it. That case is
# asserted below anyway, because the exact-directory rule is what keeps it
# true rather than the accident of a trailing slash in a glob.
#
# NO PATH ARITHMETIC, AND THAT IS THE POINT. A target carrying a "." or ".."
# component is REFUSED outright rather than folded, and so is one carrying a
# doubled or trailing slash. Folding would be claiming to know where a path
# LANDS, which is a different and racy question from the one being asked —
# normalize_dir's header makes the same argument about the PREFIX gate — and
# every shape refused here is one no install ever wrote: each link was
# `ln -sfn "$BIN_DIR/<name>"`, absolute and clean. So the refusal costs nothing
# real and fails toward KEEP, the direction every guard here fails in.
#
# THE DIRECTORY MUST BE $BIN_DIR EXACTLY, not merely a prefix of the target.
link_target_is_ours() {
    _ltio_t="$(readlink "$1" 2>/dev/null)"
    [ -n "$_ltio_t" ] || return 1
    # Absolute only: every link this project created was an absolute
    # "$BIN_DIR/<name>". A relative target is somebody else's by construction.
    case "$_ltio_t" in
    /*) ;;
    *) return 1 ;;
    esac
    # The trailing slash makes the LAST component testable the same way as
    # every other one; an absolute path's FIRST component can never be "." or
    # "..", so no leading guard is needed.
    case "$_ltio_t/" in
    */./* | */../* | *//*) return 1 ;;
    esac
    _ltio_b="${BIN_DIR:-}"
    [ -n "$_ltio_b" ] || return 1
    # One trailing slash tolerated on $BIN_DIR, which is caller-supplied.
    # Nothing else about it is normalised: every other reader uses it raw, and
    # a second spelling here would be a second answer to "where is the install".
    _ltio_b="${_ltio_b%/}"
    [ "${_ltio_t%/*}" = "$_ltio_b" ] || return 1
    # Something must remain after the directory: "$BIN_DIR" itself names no file.
    [ -n "${_ltio_t##*/}" ] || return 1
    return 0
}
# --- end LINK OWNERSHIP ------------------------------------------------------

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
# operator_login_shell — the LOGIN SHELL of the account this install is FOR, on
# stdout, or empty and non-zero when there is no such account to advise.
#
# THREE STATES, AND THEY ARE NOT THE SAME. The privileged installers run under
# `curl … | sudo sh`, where $SHELL and $HOME describe root and the account that
# will actually type `burrowee` is $SUDO_USER; the cli and agent installers run
# unprivileged, where this process IS that account and $SHELL is exact; and a
# genuine root session has no operator behind it at all.
#
#   $SUDO_USER set        the elevation record names the subject. Its login
#                         shell comes from the passwd database
#                         (login_shell_of_user), never from $SHELL — sudo does
#                         not reset $SHELL, so under sudo it is whatever
#                         invoked sudo, and under `sudo -i` or cron it is
#                         root's. Unresolvable is a REFUSAL, not a fallback to
#                         $SHELL: an advice block naming the wrong shell's
#                         profile is worse than one naming none.
#   unset, unprivileged   this run is the operator's own shell. $SHELL is the
#                         answer and no lookup is needed.
#   unset, euid 0         a root login. Nobody invoked this, so there is no
#                         operator to advise and the caller prints the generic
#                         block.
#
# The environment is read only to SELECT, per privilege.md §3.2: a $SUDO_USER
# naming no account resolves to nothing rather than inventing a subject, and
# nothing here is granted by the variable — the only thing it steers is which
# profile file a printed line names.
# ---------------------------------------------------------------------------
operator_login_shell() {
    case "${SUDO_USER:-}" in
    '' | root)
        if [ "$(id -u)" = 0 ]; then return 1; fi
        [ -n "${SHELL:-}" ] || return 1
        printf '%s\n' "$SHELL"
        return 0
        ;;
    esac
    login_shell_of_user "$SUDO_USER"
}

# ---------------------------------------------------------------------------
# render_path_advice <bin-dir> — the "Next steps" block every installer ends
# with: how to reach <bin-dir> from the operator's own shell, in that shell's
# syntax, naming the profile file that makes it permanent.
#
# WHY THIS EXISTS AT ALL. 0.3 moved the exec root to /usr/local/burrowee/bin,
# which is on nobody's PATH, and the installers linked the operator-typed names
# back into /usr/local/bin to compensate — but only where that directory proved
# root-secure. On a clean modern Mac /usr/local/bin DOES NOT EXIST, so the
# check answered "absent", nothing was linked, and the operator was handed a
# successful install with no command they could type. That was not the rare
# branch: it is the normal outcome on the newest hosts, and an Intel Mac whose
# /usr/local/bin Homebrew owns fails the same check for the opposite reason.
# The link step is gone; this block is what replaces it.
#
# IT IS PRINTED, NEVER APPLIED. The privileged installers' euid is 0 and a
# shell profile lives inside a human's home directory, which is neither of the
# two things elevation exists for (privilege.md: writing a system config file,
# installing a system daemon). Nothing here writes, sources or evals anything;
# the operator runs the line by hand. That is one paste against a privilege
# surface we then do not have.
#
# IT IS PRINTED UNCONDITIONALLY, on every successful install including a
# re-install that changed nothing. "Is it already on PATH?" is a question this
# process cannot answer: under sudo it sees root's secure_path, not the
# operator's interactive PATH, and reconstructing one by sourcing their profile
# as root is far worse than a paragraph that is sometimes redundant.
#
# STDOUT, not stderr. It is the successful outcome of the run, not a
# diagnostic.
#
# <bin-dir> IS AN ARGUMENT, not a global. The same function serves the system
# components (/usr/local/burrowee/bin) and the per-user cli and agent
# (${PREFIX:-$HOME/.local}/bin), and a component installer that sources this
# library gets the identical block without knowing anything about it.
#
# THE SHELL SET WAS CHOSEN, NOT GUESSED. zsh is macOS's default and the
# reported host's; bash is the Linux default and needs a different file on each
# platform (.bash_profile is read by a macOS login shell, .profile by a Linux
# one); fish shares no syntax with either — no `export`, and `fish_add_path` is
# what records a path for every future session. Anything else gets the POSIX
# export line and NO file name: guessing a startup file for an unknown shell is
# how an operator ends up editing something their shell never reads.
# ---------------------------------------------------------------------------
render_path_advice() {
    _rpa_dir="$1"
    [ -n "$_rpa_dir" ] || return 0

    _rpa_shell="$(operator_login_shell 2>/dev/null || true)"
    # The home is resolved from the SAME subject the shell was, and only when a
    # shell was resolved at all — so the $HOME branch below can never be root's:
    # operator_login_shell has already refused the euid-0-with-no-$SUDO_USER
    # case. One subject, one answer, both halves travelling together
    # (privilege.md §3.1).
    _rpa_home=""
    if [ -n "$_rpa_shell" ]; then
        case "${SUDO_USER:-}" in
        '' | root) _rpa_home="${HOME:-}" ;;
        *) _rpa_home="$(home_of_user "$SUDO_USER" 2>/dev/null || true)" ;;
        esac
    fi

    _rpa_profile=""
    _rpa_permanent=""

    # THE SYNTAX IS THE SHELL'S, AND IT DOES NOT DEPEND ON THE HOME. Only the
    # PROFILE FILE does. These two questions were once answered in one `case`
    # under `[ -n "$_rpa_home" ]`, and the difference is not academic:
    # login_shell_of_user falls back to reading /etc/passwd, which home_of_user
    # does not, so on a slim image with neither getent nor dscl the shell
    # resolves and the home does not — and a fish operator was then handed
    # `export PATH="…:$PATH"`, which fish rejects. Syntax first,
    # unconditionally; the file second, only when there is a home to put it in.
    case "${_rpa_shell##*/}" in
    fish) _rpa_now="set -gx PATH $_rpa_dir \$PATH" ;;
    *)    _rpa_now="export PATH=\"$_rpa_dir:\$PATH\"" ;;
    esac

    if [ -n "$_rpa_home" ]; then
        case "${_rpa_shell##*/}" in
        zsh)
            _rpa_profile="$_rpa_home/.zprofile"
            ;;
        bash)
            # A macOS login shell reads .bash_profile and never .profile; a
            # Linux one reads .profile. Naming the wrong one is advice that
            # silently does nothing on the next login.
            if [ "$(uname -s)" = "Darwin" ]; then
                _rpa_profile="$_rpa_home/.bash_profile"
            else
                _rpa_profile="$_rpa_home/.profile"
            fi
            ;;
        fish)
            _rpa_profile="$_rpa_home/.config/fish/config.fish"
            _rpa_permanent="fish_add_path $_rpa_dir"
            ;;
        esac
    fi
    if [ -n "$_rpa_profile" ] && [ -z "$_rpa_permanent" ]; then
        _rpa_permanent="echo '$_rpa_now' >> $_rpa_profile"
    fi

    echo ""
    echo "==> Next steps"
    echo "burrowee's commands are in $_rpa_dir, which is not on your PATH."
    echo ""
    echo "  Add it to this shell now:"
    echo "    $_rpa_now"
    echo ""
    if [ -n "$_rpa_profile" ]; then
        echo "  Make it permanent:"
        echo "    $_rpa_permanent"
        case "${_rpa_shell##*/}" in
        fish) echo "    (that records it for every fish session; $_rpa_profile works too)" ;;
        esac
    else
        echo "  Make it permanent by adding the line above to your shell's startup file."
    fi
    echo ""
    echo "  Then:  burrowee help"
    # An advisory message must never be able to end an install: every caller
    # runs under `set -e` and calls this last.
    return 0
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
    # ONCE PER PROCESS. An installer runs both sweeps — the per-user one and
    # the exec-root one — and each ends by calling this on a run that removed
    # something. The sentence is about ONE shell's hash table; saying it twice
    # in one install reads as two different problems.
    [ "${STALE_BIN_SHELL_HINT_SAID:-0}" = 1 ] && return 0
    STALE_BIN_SHELL_HINT_SAID=1
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
# SYMLINKS: OURS GO, EVERYONE ELSE'S STAY — and this rule INVERTED, so the
# reason the old one was right is worth keeping. Every symlink here used to be
# spared, checked FIRST and before ownership (a link's stamp is its target's),
# because "the 0.3 installer links the operator-typed names from /usr/local/bin
# into the new tree (spec §6.1); deleting one of those is deleting the install's
# PATH entry." That sentence was true and is now false: nothing links there any
# more. §6.1 is superseded, the installers print an export line for the
# operator's own shell instead, and a link into $BIN_DIR is therefore not the
# install's PATH entry but a leftover of an earlier 0.3 install — sitting in a
# directory an operator's PATH reaches AHEAD of the exec root.
#
# Three shapes, three decisions, because they are not the same question:
#   * OURS — the link resolves and its target is under $BIN_DIR. Removed.
#     Removing a link removes no binary: the target it named is exactly what
#     $BIN_DIR still holds, which is why the twin guard below does not apply to
#     it. The UNIT guard does, for the reason it always did.
#   * THEIRS — it resolves somewhere else. An operator's own wrapper. Left.
#   * DANGLING — it does not resolve at all, so nothing can say whose it was.
#     Left: undecidable cases fail toward KEEP, here as everywhere else.
#
# WHAT IT DOES NOT TOUCH, per item, and why:
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
# what it decides about them.
#
# NOTHING SETS IT ANY MORE, and that is the whole second-order effect of
# deleting the link step. The installers used to hand it every operator-typed
# name they had not linked: on a host whose /usr/local/bin was not root-secure
# nothing was linked, and the real 0.2 file at that name was then the ONLY copy
# anything reached by the absolute path — the shared `burrowee` dispatcher
# above all, which every co-installed component resolved as
# /usr/local/bin/burrowee. Removing it there would have left that path empty on
# exactly the host class this change exists for.
#
# No consumer resolves by that path today: no install links there, and $BIN_DIR
# is what every unit, every root exec and the printed PATH advice name. So the
# list is empty on every host, and the real-file removals a first 0.3 run used
# to defer happen on that first run. Intended, and asserted rather than merely
# allowed (inner/edge/install_test/exec_root_sweep_test.go).
#
# It survives as a SEAM rather than being deleted: it is what lets a suite that
# cannot create root-owned files drive the keep branch in both directions
# (tools/test-shared-migrations.sh 37a4, 37a5), and a guard no test can enter
# is a guard that can be deleted without anything going red.
STALE_EXEC_ROOT_KEEP="${STALE_EXEC_ROOT_KEEP:-}"

# ARE $LEGACY_BIN_DIR AND $BIN_DIR THE SAME DIRECTORY? Two callers ask, and
# THEIR SAFE DIRECTIONS ARE OPPOSITE, which is why there are two entry points
# over one resolver instead of one function with one answer:
#
#   remove_stale_exec_root_bins  DELETES. Its wrong answer unlinks binaries the
#     installer has just placed, so where the truth cannot be established it
#     must answer SAME and decline to sweep. Wrong cost: one skipped no-op run.
#     → stale_exec_root_same_dir_for_sweep
#
#   stale_exec_root_bins_pending  is the rung's --applies PROBE, and is
#     documented FAIL-OPEN: a legacy tree it cannot read is "still needed",
#     never "nothing there". Its wrong answer records the rung as done and
#     strands the stale copies forever, so where the truth cannot be
#     established it must answer DIFFERENT and leave the work pending. Wrong
#     cost: one no-op run.
#     → stale_exec_root_same_dir_for_probe
#
# One helper serving both is the defect this shape exists to prevent: the
# single function answered "same" on an unresolvable destination — right for
# the sweep, and for the probe it turned `--applies` into "no" for any host
# whose $BIN_DIR does not resolve, silently retiring a rung that had done
# nothing. A future edit that changes one fallback now cannot touch the other.
#
# RESOLVED PHYSICALLY, not compared as text. The first fix here collapsed
# repeated slashes and stripped trailing ones with sed, which is the body of
# install.sh's normalize_dir — and that function says out loud what it is:
# "TEXTUAL ONLY — no '.'/'..' folding, no symlink resolution, no relative-path
# anchoring". Every spelling the text compare cannot see is a live way to
# delete the install: `/usr/local/bin/.` and `/usr/local/bin/../bin` fold to
# the destination, a relative spelling anchors to it, and a symlinked alias
# resolves to it.
#
# `cd -P`, NOT a bare `cd`, and that is the same logical-versus-physical
# distinction the root-secure walk beside this was rewritten to respect. A bare
# `cd` is LOGICAL: the shell folds a `..` textually instead of letting the
# kernel resolve it, so `<legacy>/link/../bin`, where `link` is a symlink, is
# folded to a path that does not exist and the `cd` FAILS — after which the
# text compare answers "different" about the install destination itself.
#
# The `cd` runs in a command substitution, so it is a SUBSHELL and the sourcing
# installer's own working directory never moves. CDPATH is cleared because a
# relative operand would otherwise be resolved against it.
#
# Deliberately NOT named normalize_dir: inner/*/install.sh defines one and
# sources this library from inside a function, so a second definition of that
# name would silently take over for the rest of that shell.

# stale_exec_root_resolve_pair LEGACY DESTINATION — sets $_sersd_ra / $_sersd_rb
# to each side resolved by the kernel, or to '' for a side that will not
# resolve. The shared half; neither fallback lives here.
stale_exec_root_resolve_pair() {
    _sersd_ra="$(CDPATH= cd -P -- "$1" 2>/dev/null && pwd -P)" || _sersd_ra=''
    _sersd_rb="$(CDPATH= cd -P -- "$2" 2>/dev/null && pwd -P)" || _sersd_rb=''
}

# stale_exec_root_same_text LEGACY DESTINATION — the textual compare, kept only
# as a POSITIVE short-circuit: two identical spellings are certainly the same
# directory whether or not either resolves. It can never prove they DIFFER.
stale_exec_root_same_text() {
    _sersd_a="$(printf '%s' "$1" | sed -e 's|//*|/|g' -e 's|/*$||')"
    _sersd_b="$(printf '%s' "$2" | sed -e 's|//*|/|g' -e 's|/*$||')"
    [ "${_sersd_a:-/}" = "${_sersd_b:-/}" ]
}

# For the SWEEP: unresolvable ⇒ SAME ⇒ do not delete.
stale_exec_root_same_dir_for_sweep() {
    stale_exec_root_resolve_pair "$1" "$2"
    if [ -n "$_sersd_ra" ] && [ -n "$_sersd_rb" ]; then
        [ "$_sersd_ra" = "$_sersd_rb" ]
        return $?
    fi
    # A destination this run cannot identify is one nothing may be deleted
    # against. A legacy side that will not resolve cannot be entered either, so
    # the sweep could unlink nothing out of it: the text compare is safe there
    # and preserves the probe's fail-open shape for the caller below.
    [ -n "$_sersd_rb" ] || return 0
    stale_exec_root_same_text "$1" "$2"
}

# For the PROBE: unresolvable ⇒ DIFFERENT ⇒ the rung stays pending.
stale_exec_root_same_dir_for_probe() {
    stale_exec_root_resolve_pair "$1" "$2"
    if [ -n "$_sersd_ra" ] && [ -n "$_sersd_rb" ]; then
        [ "$_sersd_ra" = "$_sersd_rb" ]
        return $?
    fi
    # Identical spellings still prove sameness; nothing else does. Anything
    # unproven leaves the rung pending, which is this caller's fail-open.
    stale_exec_root_same_text "$1" "$2"
}

# stale_exec_root_is_kept NAME — true when NAME is in $STALE_EXEC_ROOT_KEEP.
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
# name at $LEGACY_BIN_DIR, as one word: link-foreign | link-dangling | absent |
# irregular | foreign | no-twin | twin-untrusted | unit:<file> | remove |
# remove-link. One function, used by the probe and the sweep alike, for the
# reason stale_bin_decision gives.
#
# THERE IS NO `link-ours`. A link of ours is not a verdict on its own: it still
# has to clear the unit guard, so it leaves here as either `unit:<file>` or
# `remove-link` and never as a word of its own. The word was listed here once
# and emitted nowhere, which is the shape that makes a reader add a dead arm to
# a caller's `case`.
stale_exec_root_decision() {
    _serd_p="$LEGACY_BIN_DIR/$1"
    # stale_bin_verdict answers `symlink` FIRST, before ownership — a link's
    # stamp is its target's — which is exactly the order this sweep needs.
    _serd_v="$(stale_bin_verdict "$_serd_p")"
    case "$_serd_v" in
    symlink)
        # `-e` FOLLOWS the link, so it is the resolution test: a link that does
        # not resolve tells us nothing about whose it was and is kept.
        [ -e "$_serd_p" ] || { echo link-dangling; return 0; }
        # link_target_is_ours is the SAME function the installers'
        # unlink_operator_bins calls, byte for byte, so the sweep and the
        # uninstall cannot disagree about which links are ours. A link through
        # some other link is not recognised and is therefore kept, which is the
        # safe direction.
        link_target_is_ours "$_serd_p" || { echo link-foreign; return 0; }
        # The unit guard applies to a link exactly as it does to a file: on
        # macOS a 0.2 plist's KeepAlive.PathState keys off the existence of the
        # path it names, so unlinking one a supervisor still watches stops the
        # running daemon. The TWIN guard does not — removing a link removes no
        # binary at all, and the target it named is what $BIN_DIR still holds.
        if _serd_u="$(unit_naming_bin "$LEGACY_BIN_DIR" "$1" "$2")"; then
            echo "unit:$_serd_u"
            return 0
        fi
        echo remove-link
        return 0
        ;;
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
    ! stale_exec_root_same_dir_for_probe "$LEGACY_BIN_DIR" "$BIN_DIR" || return 1
    _serp_dir="$LEGACY_BIN_DIR"
    [ -r "$_serp_dir" ] && [ -x "$_serp_dir" ] || return 0
    _serp_home="$(operator_home 2>/dev/null)"
    for _serp_b in $STALE_USER_BINS; do
        stale_exec_root_is_kept "$_serp_b" && continue
        case "$(stale_exec_root_decision "$_serp_b" "$_serp_home" 2>/dev/null)" in
        remove | remove-link) return 0 ;;
        esac
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
    ! stale_exec_root_same_dir_for_sweep "$LEGACY_BIN_DIR" "$BIN_DIR" || return 0
    if ! { [ -r "$LEGACY_BIN_DIR" ] && [ -x "$LEGACY_BIN_DIR" ]; }; then
        echo "note: cannot read $LEGACY_BIN_DIR — its stale burrowee copies were not swept." >&2
        return 0
    fi
    _rser_home="$(operator_home 2>/dev/null)"
    for _rser_b in $STALE_USER_BINS; do
        _rser_p="$LEGACY_BIN_DIR/$_rser_b"
        if stale_exec_root_is_kept "$_rser_b"; then
            [ -e "$_rser_p" ] && echo "kept $_rser_p — \$STALE_EXEC_ROOT_KEEP names it, so this sweep leaves it alone"
            continue
        fi
        _rser_d="$(stale_exec_root_decision "$_rser_b" "$_rser_home")"
        case "$_rser_d" in
        absent) ;;
        link-foreign)
            echo "kept $_rser_p — a symlink pointing outside $BIN_DIR, so it is not ours"
            ;;
        link-dangling)
            echo "kept $_rser_p — a symlink whose target does not resolve, so nothing can say whose it is"
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
        remove-link)
            # A link an EARLIER 0.3 install made, back when there was a link
            # step. It removes no binary — $BIN_DIR/$_rser_b is what it named
            # and is what stays — and it clears a name an operator's PATH
            # reaches ahead of the exec root.
            if rm -f "$_rser_p"; then
                echo "removed stale 0.3 exec-root link: $_rser_p (the install is $BIN_DIR/$_rser_b)"
            else
                echo "note: could not remove the link $_rser_p — remove it by hand." >&2
            fi
            ;;
        esac
    done
    return 0
}
