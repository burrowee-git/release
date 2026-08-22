#!/bin/sh
# _shared/migrations/upgrade.sh <version> — force the state migrations from
# the inclusive floor <version> up.
#
#     sh migrations/upgrade.sh 0.2.0
#
# *** THIS IS NOT HOW YOU UPGRADE. install.sh IS. ***
# The routine upgrade places the binaries and then walks the ladder gated, one
# version at a time, reading what this host actually recorded. Nothing about
# that changes, and nothing here installs anything: this script runs migrations
# and only migrations, so there stays exactly one place that places binaries and
# exactly one that migrates state. If you are here because an upgrade is due,
# run the installer.
#
# WHAT IT IS FOR: the cases the gate cannot see. The gate compares only
# MAJOR.MINOR.PATCH and deliberately ignores the .date.sha tail, so a host that
# changed BUILD without changing SEMVER —
# 0.2.0.2026.08.08.79a5cfd7 → 0.2.0.2026.08.17.4e43c2ed — is invisible to it and
# looks already migrated. Same for an anchor that is missing or wrong. Without
# this script the operator has to know to pass two flags, on a host mid-incident.
#
# ONE FILE FOR EVERY COMPONENT THAT TAKES THE SHARED RUNNER. It is authored once
# in the release repo and staged into each kit beside run.sh, exactly as the
# runner is. The gateway has its own copy of this script for the same reason it
# has its own runner (see run.sh's header); the two are deliberately the same
# shape so an operator who has used one recognises the other.
#
# WHAT IT RUNS, exactly:
#
#     run.sh --assume-below <version> --rerun-recorded
#
# THE ARGUMENT IS AN INCLUSIVE FLOOR — "assume this host is below <version>".
# The anchor is ignored, the per-rung gate is bypassed, and every rung targeting
# <version> OR NEWER runs; rungs targeting strictly older lines are skipped as
# genuinely done. The kit bounds the top (a 0.2.1 release zip carries only rungs
# up to 0.2.1); the floor bounds the bottom, and an operator forcing 0.2.0's
# work on a host whose 0.1.x rungs really did run should not have that older
# work reopened as a side effect. Passing the ladder's own newest target as the
# floor — what the public upgrade bootstrap does by default — still selects the
# newest line's whole rung set, which for a single-line ladder is everything.
#
# --rerun-recorded IS ACCEPTABLE HERE BECAUSE THIS IS THE OVERRIDE. An operator
# running it has already decided to force, so reopening receipted rungs is a
# choice rather than a surprise. It is still not free: today every rung is
# idempotent, but the first rung that rewrites, prunes or re-keys state makes a
# silent blanket re-run harmful. So the list of rungs about to be re-run is
# printed BEFORE any of them runs.
#
# AND ONE RUNG NOW READS IT AS MORE THAN "DO IT AGAIN". run.sh passes
# --rerun-recorded down as $MIGRATION_FORCED=1, and adopt_user_tree.sh turns that
# into `migrate --force`: it OVERWRITES the destination — identity, bridge keys,
# console pin and config — from the running user's tree, after snapshotting both
# destination roots. That is not a widening of this script's meaning but the
# whole of it: on a host whose tree was adopted from the WRONG source, the
# adoption never overwrites and so re-running it is a guaranteed no-op, which is
# precisely the state that left an operator copying key material by hand on a
# production node. See adopt_user_tree.sh's header. The rung announces the
# forced run and names every file it replaced.
#
# THE FLOOR IS ALSO THE CROSS-CHECK, and one direction of it is ENFORCED. This
# script ships once and takes the floor as an argument — there is no per-release
# copy to render or sign — so nothing else would notice an operator who unpacked
# a 0.2.0 kit and typed `upgrade.sh 0.3.0`. A floor ABOVE the newest target in
# THIS kit's ledger is a wrong belief about the kit — it has no such migration
# to force, and the honest answer is a refusal naming both values, never a
# silent empty run. A floor BELOW the top is the opposite of a mistake: it is
# the normal backfill ("this host missed the 0.2.0 work"), and refusing it —
# or demanding equality — would break the forcing path on the first release
# that ships no new rung, when the release line moves past a ladder that
# didn't. The ledger's newest target is the only version statement a
# migrations-only script can read without executing a binary, and the one that
# decides what forcing can possibly do here.
#
# IT INSTALLS NOTHING. No binary is placed, no unit is written, no version
# anchor is recorded. The ladder's exit code is propagated unchanged so a caller
# — or an operator's `echo $?` — sees what the runner decided and not what this
# wrapper felt about it.
#
# RUN IT AS THE ACCOUNT THAT OWNS THE COMPONENT TREE. For a `user`-scheme
# component (cli) that is the operator; for a `root`-scheme one (edge) it is
# root. The runner resolves the tree from the scheme its component.conf
# declares, so it is the one place that decision is made.
#
# EXIT CODES: run.sh's, verbatim (0 nothing applied · 1 refused/failed · 2 ran ·
# 3 ran but a receipt was lost), plus 64 for a wrong command line, which is also
# run.sh's code for that.
#
# THIS SCRIPT STARTS NOTHING, AND FOR SOME LADDERS THAT MATTERS. The runner
# itself stops nothing, but a RUNG may — a component declares which ones in
# migrations/component.conf's $SERVICE_STOP_RUNGS, and adopt_user_tree.sh is the
# first. install.sh and update.sh restart the daemon after walking the ladder;
# this script deliberately does not install or restart anything, so on a
# component with such a rung exit 2 can leave the daemon down. The runner's own
# last line says whether it did, and the exit-2 note below points at it rather
# than repeating a claim it cannot check.
set -eu

HERE="$(dirname "$0")"
RUNNER="$HERE/run.sh"
LEDGER="$HERE/ledger"
CONF="$HERE/component.conf"

# ---------------------------------------------------------------------------
# THE DESTINATION CROSSES THIS BOUNDARY EXPLICITLY, and canonically.
#
# run.sh would otherwise re-derive it: BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}".
# That was safe only while nothing could hand this script a PREFIX — and the
# root-only installers' gate now ACCEPTS any spelling whose bin dir resolves to
# their destination, so `PREFIX=/usr/local/` is a legal, supported invocation
# that reaches here verbatim (the public upgrade bootstrap exports what the
# operator set; an operator running this script by hand exports it themselves).
# Re-derived, that becomes BIN_DIR=/usr/local//bin.
#
# Nothing fails to OPEN — every filesystem call tolerates the doubled slash. What
# breaks is the string work downstream: lib_stale_user_bins.sh decides "never
# sweep the install destination" by comparing directory NAMES, and
# `/usr/local//bin` matches none of the spellings it knows. A guard that silently
# stops recognising the directory it is protecting is the worst shape this can
# take, because the sweep still reports success.
#
# So: resolved once, here, with the same two substitutions the installers'
# normalize_dir applies, and exported. An explicitly-passed BIN_DIR still wins,
# and is normalised too — a caller that spelled it loosely gets the same
# treatment as one that spelled PREFIX loosely.
#
# printf, never echo: echo expands backslash escapes in dash and in macOS
# /bin/sh, which would rewrite the path rather than normalise it.
BIN_DIR="$(printf '%s' "${BIN_DIR:-${PREFIX:-/usr/local}/bin}" | sed -e 's|//*|/|g' -e 's|/*$||')"
BIN_DIR="${BIN_DIR:-/}"
export BIN_DIR

# The component's own facts, for the exit-2 note only. Sourced defensively: an
# absent or unreadable conf makes the note generic, and the runner has already
# refused the whole run in that case anyway.
COMP=""
SERVICE_STOP_RUNGS=""
if [ -f "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
fi

# A bare `say` prints a blank line rather than a bare prefix: the output below
# is read mid-incident and the paragraphs are what make it readable.
say()  { if [ -z "${1:-}" ]; then echo; else echo "upgrade: $*"; fi; }
warn() { echo "upgrade: $*" >&2; }

usage() {
    cat <<EOF
usage: sh $0 <version>

Force this kit's state migrations from the inclusive floor <version> up.
Migrations ONLY — this installs nothing. The normal way to upgrade is the
installer; use this when the ladder's version gate cannot see that this host
needs migrating (a missing or wrong anchor, the same semver on a different
build, or a host that reached a newer version while an older line's rungs
never ran).

  <version>   the INCLUSIVE FLOOR — "assume this host is below <version>", e.g.
              0.2.0. A leading "v" and a release stamp's trailing .date.sha are
              accepted. Rungs targeting <version> or newer run with receipts
              reopened; rungs targeting older lines are skipped as genuinely
              done. REFUSED only when it is ABOVE the newest target in this
              kit's ladder — that kit has no such migration to force. A floor
              below the top is the normal backfill, not a mistake.

It runs:  sh $RUNNER --assume-below <version> --rerun-recorded
and prints the rungs it is about to re-run before running any of them.

A rung may read the forced flag and OVERWRITE state it would otherwise leave
alone. adopt_user_tree.sh does: forced, it replaces this component's identity,
bridge keys, console pin and config with the running user's tree, after
snapshotting both destination roots to siblings it names. That is the repair for
a tree adopted from the wrong source, and it is not something to type by mistake.

Run it as the account that owns this component's tree.

Exit codes are the runner's: 0 nothing applied · 1 refused/failed · 2 ran ·
3 ran but a receipt was lost · 64 the command line was wrong.
EOF
}

usage_error() {
    warn "$1"
    usage >&2
    exit 64
}

# ---------------------------------------------------------------------------
# norm_version <string> — MAJOR.MINOR.PATCH, or non-zero when the value is not
# something this script may compare.
#
# Same acceptance as run.sh's valid_version, and for the same reason: a
# non-numeric field reads as 0 in the gate, so "0.2.x" would quietly compare as
# 0.2.0 and pass a cross-check the operator's actual belief would have failed.
# ---------------------------------------------------------------------------
norm_version() {
    _nv="${1##*/}"
    _nv="${_nv#v}"
    case "$_nv" in
    *.*.*) ;;
    *) return 1 ;;
    esac
    _nv_major="${_nv%%.*}"
    _nv_rest="${_nv#*.}"
    _nv_minor="${_nv_rest%%.*}"
    _nv_rest="${_nv_rest#*.}"
    _nv_patch="${_nv_rest%%.*}"
    _nv_patch="${_nv_patch%%-*}"
    _nv_patch="${_nv_patch%%+*}"
    for _nv_f in "$_nv_major" "$_nv_minor" "$_nv_patch"; do
        case "$_nv_f" in
        '' | *[!0-9]*) return 1 ;;
        esac
    done
    printf '%s.%s.%s\n' "$_nv_major" "$_nv_minor" "$_nv_patch"
}

# ---------------------------------------------------------------------------
# line_lt <a> <b> — true when version a is strictly older than b, comparing the
# first three fields NUMERICALLY. Both values arrive already normalized through
# norm_version, so the fields are bare numbers; the shape mirrors the runner's
# version_lt so the two scripts cannot disagree about an ordering.
# ---------------------------------------------------------------------------
line_lt() {
    _ll_n=1
    while [ "$_ll_n" -le 3 ]; do
        _ll_x="$(printf '%s' "$1" | cut -d. -f"$_ll_n")"
        _ll_y="$(printf '%s' "$2" | cut -d. -f"$_ll_n")"
        if [ "$_ll_x" -lt "$_ll_y" ]; then return 0; fi
        if [ "$_ll_x" -gt "$_ll_y" ]; then return 1; fi
        _ll_n=$((_ll_n + 1))
    done
    return 1    # equal is not older
}

# ---------------------------------------------------------------------------
# read_ledger <ledger> — the ladder, as awk sees it. First line is the NEWEST
# target in the ledger; every line after it is "<target> <script>" in ledger
# order.
#
# The ledger is a data FILE for this runner — unlike the gateway's, whose ledger
# is a here-string inside run.sh and has to be parsed out of it. Word-split into
# (version, script) pairs exactly as the runner splits it, so the two cannot
# disagree about what the ledger says.
#
# The newest target is computed by NUMERIC comparison rather than taken as the
# last row. Ledger order is the runner's contract, not this script's to assume,
# and two rows may legitimately share a target — so "the last row" and "the
# newest version" are not the same question.
# ---------------------------------------------------------------------------
read_ledger() {
    awk '
        function vf(v, i,   a, n, f) {
            n = split(v, a, ".")
            if (i > n) return 0
            f = a[i]
            sub(/[-+].*/, "", f)
            if (f !~ /^[0-9]+$/) return 0
            return f + 0
        }
        function newer(a, b,   i, x, y) {
            for (i = 1; i <= 3; i++) {
                x = vf(a, i); y = vf(b, i)
                if (x > y) return 1
                if (x < y) return 0
            }
            return 0
        }
        { sub(/#.*$/, ""); for (i = 1; i <= NF; i++) word[++c] = $i }
        END {
            if (c == 0 || c % 2 != 0) {
                print "ledger holds " c+0 " words, want (version, script) pairs" > "/dev/stderr"
                exit 1
            }
            top = word[1]
            for (i = 3; i <= c; i += 2) if (newer(word[i], top)) top = word[i]
            print top
            for (i = 1; i <= c; i += 2) print word[i] " " word[i + 1]
        }
    ' "$1"
}

# ---------------------------------------------------------------------------
# THE COMMAND LINE
# ---------------------------------------------------------------------------
WANT=""
while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help | help)
        usage
        exit 0
        ;;
    -*)
        usage_error "unknown option '$1'; this script takes one argument, the version"
        ;;
    *)
        [ -z "$WANT" ] || usage_error "unexpected extra argument '$1'; this script takes one version — the inclusive floor to force from"
        WANT="$1"
        shift
        ;;
    esac
done

[ -n "$WANT" ] || usage_error "a version is required, e.g. sh $0 0.2.0"

if ! WANT_NORM="$(norm_version "$WANT")"; then
    warn "'$WANT' is not a version this script can compare."
    warn "expected MAJOR.MINOR.PATCH, all numeric — e.g. 0.2.0, v0.2.0, or the"
    warn "release stamp 0.2.0.2026.08.17.4e43c2ed."
    warn "refusing rather than guessing: a non-numeric field reads as 0, so"
    warn "'$WANT' would have passed a cross-check against some other version."
    warn "nothing has been touched."
    exit 64
fi

if [ ! -f "$RUNNER" ] || [ ! -f "$LEDGER" ]; then
    warn "no ladder beside this script: $RUNNER and $LEDGER must both be here."
    warn "upgrade.sh forces the ladder in the kit it ships inside — run it from the"
    warn "unzipped release, or from the installed copy beside the binaries."
    warn "nothing has been touched."
    exit 1
fi

if ! LEDGER_ROWS="$(read_ledger "$LEDGER")"; then
    warn "could not read the ladder out of $LEDGER (message above)."
    warn "refusing: without the ledger this script cannot say what it would force,"
    warn "and forcing a ladder it cannot describe is exactly what it exists to avoid."
    warn "nothing has been touched."
    exit 1
fi

KIT_VERSION="$(printf '%s\n' "$LEDGER_ROWS" | head -n 1)"
ROWS="$(printf '%s\n' "$LEDGER_ROWS" | sed -n '2,$p')"

if ! KIT_NORM="$(norm_version "$KIT_VERSION")"; then
    warn "the newest target in $LEDGER is '$KIT_VERSION', which is not a version"
    warn "this script can compare. That is a defect in the ladder, not in your"
    warn "command line. nothing has been touched."
    exit 1
fi

# THE CROSS-CHECK — one direction only. A floor ABOVE the kit's newest target
# names a migration this kit does not carry: refuse, both sides named, both
# values printed. A floor below the top is the normal backfill and passes —
# demanding equality here would break the forcing path on the first release
# whose line moved past a ladder that didn't ship a new rung.
if line_lt "$KIT_NORM" "$WANT_NORM"; then
    warn "REFUSING: you asked to force migrations from $WANT_NORM up, but this kit's"
    warn "ladder tops out at $KIT_NORM — it has no $WANT_NORM migration to force."
    warn "  floor:      $WANT_NORM  (from the argument '$WANT')"
    warn "  ladder top: $KIT_NORM  (the newest target in $LEDGER)"
    warn "one of those is not what you think it is: either this is not the kit for the"
    warn "release you mean, or the release you mean has no migration in it."
    warn "unpack the kit for the release you are moving to, and re-run it from there."
    warn "nothing has been touched — no migration ran, and nothing was installed."
    exit 64
fi

# ---------------------------------------------------------------------------
# SAY WHAT IS ABOUT TO BE RE-RUN, BEFORE RUNNING IT — the floor's selection,
# computed here exactly as the runner will compute it: targets at or above the
# floor run, strictly older targets are done.
# ---------------------------------------------------------------------------
say "forcing the state migrations from floor $WANT_NORM up, via $RUNNER."
say "this is the OVERRIDE, not the upgrade: install.sh places the binaries and"
say "walks this same ladder gated. nothing here installs anything."
say ""
say "every rung targeting $WANT_NORM or newer will be re-run, including any whose"
say "receipt says it already completed here:"
_selected=0
_skipped=0
# No pipeline: a `| while` subshell could not carry the counters back out.
_OLDIFS="$IFS"; IFS='
'
for _row in $ROWS; do
    IFS="$_OLDIFS"
    _v="${_row%% *}"
    _s="${_row#* }"
    [ -n "$_s" ] && [ "$_s" != "$_row" ] || { IFS='
'; continue; }
    if _v_norm="$(norm_version "$_v")" && ! line_lt "$_v_norm" "$WANT_NORM"; then
        say "  $_s (target $_v)"
        _selected=$((_selected + 1))
    else
        _skipped=$((_skipped + 1))
    fi
    IFS='
'
done
IFS="$_OLDIFS"
if [ "$_skipped" -gt 0 ]; then
    say "($_skipped older rung(s) below the floor are treated as genuinely done and skipped)"
fi
say ""
say "read those rungs if you have not: an idempotent rung is close to free to"
say "repeat, a rung that rewrites or prunes state is not."
say ""

# ---------------------------------------------------------------------------
# Run it. `set +e` around the call only: the runner's non-zero codes are its
# contract, not a failure of this script, and `set -e` would abort here and
# swallow the code the caller is waiting for.
# ---------------------------------------------------------------------------
set +e
sh "$RUNNER" --assume-below "$WANT_NORM" --rerun-recorded
CODE=$?
set -e

say ""
case "$CODE" in
0)
    say "the ladder applied nothing (exit 0). Every rung declined on this host's own"
    say "evidence even with the gate forced open — so there was nothing here to force."
    ;;
1)
    say "the ladder REFUSED or FAILED (exit 1). Read its output above: either nothing"
    say "was touched, or a rung failed."
    ;;
2)
    if [ -n "${SERVICE_STOP_RUNGS:-}" ]; then
        # NOT "the daemon is down": this script forces every rung, and a rung
        # that declined (nothing to adopt, already adopted) stopped nothing. The
        # runner's last line is the one that knows, and pointing at it beats
        # inventing a second, weaker answer here.
        say "the migrations ran (exit 2). This ladder contains a rung that STOPS"
        say "burrowee-${COMP:-<component>} ($SERVICE_STOP_RUNGS), and this script"
        say "installs and starts nothing — read the runner's last line above: it says"
        say "whether the daemon was left stopped. If it was, start it."
    else
        say "the migrations ran (exit 2). This ladder stops no service, so there is"
        say "nothing here for you to restart."
    fi
    ;;
3)
    say "the migrations ran, but a receipt was lost (exit 3). The rung stays"
    say "re-runnable, which is the point of withholding the receipt."
    ;;
*)
    say "the ladder exited $CODE, which is not one of its documented codes."
    ;;
esac

exit "$CODE"
