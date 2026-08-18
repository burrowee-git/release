#!/bin/sh
# _shared/migrations/upgrade.sh <version> — force this line's state migrations.
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
#     run.sh --installed-version 0.0.0 --rerun-recorded
#
# THE FROM-VERSION IS 0.0.0 — every rung the shipped ladder contains, not an
# arithmetic on the target. THE KIT IS ALREADY THE BOUND: a 0.2.0 release zip
# carries only rungs up to 0.2.0, so "everything in this ladder" and "everything
# for this upgrade" are the same set. A `target − one minor` rule would be a
# second, weaker statement of the same bound, and it breaks at a major boundary.
#
# --rerun-recorded IS ACCEPTABLE HERE BECAUSE THIS IS THE OVERRIDE. An operator
# running it has already decided to force, so reopening receipted rungs is a
# choice rather than a surprise. It is still not free: today every rung is
# idempotent, but the first rung that rewrites, prunes or re-keys state makes a
# silent blanket re-run harmful. So the list of rungs about to be re-run is
# printed BEFORE any of them runs.
#
# THEN WHAT IS THE ARGUMENT FOR? A cross-check, and it is ENFORCED. This script
# ships once and takes the version as an argument — there is no per-release copy
# to render or sign — so nothing else would notice an operator who unpacked a
# 0.2.0 kit and typed `upgrade.sh 0.3.0`. That operator has a wrong belief about
# their host, and a wrong belief is worth a refusal rather than a silent no-op.
# The version is compared against the newest target in THIS kit's ledger, which
# is the only version statement a migrations-only script can read without
# executing a binary, and it is the one that decides what forcing can possibly
# do here: a kit whose ladder tops out at 0.2.0 has no 0.3.0 migration to force.
# The refusal names both values.
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
# run.sh's code for that. THIS RUNNER STOPS NO SERVICE, so 2 means migrations
# ran and nothing else — there is nothing here for an operator to restart.
set -eu

HERE="$(dirname "$0")"
RUNNER="$HERE/run.sh"
LEDGER="$HERE/ledger"

# A bare `say` prints a blank line rather than a bare prefix: the output below
# is read mid-incident and the paragraphs are what make it readable.
say()  { if [ -z "${1:-}" ]; then echo; else echo "upgrade: $*"; fi; }
warn() { echo "upgrade: $*" >&2; }

usage() {
    cat <<EOF
usage: sh $0 <version>

Force every state migration this kit's ladder contains, for the <version> line.
Migrations ONLY — this installs nothing. The normal way to upgrade is the
installer; use this when the ladder's version gate cannot see that this host
needs migrating (a missing or wrong anchor, or the same semver on a different
build).

  <version>   the release line this kit is for, e.g. 0.2.0. A leading "v" and a
              release stamp's trailing .date.sha are accepted. REFUSED when it
              does not match the newest target in this kit's ladder — that
              mismatch means one of the two is not what you think it is.

It runs:  sh $RUNNER --installed-version 0.0.0 --rerun-recorded
and prints the rungs it is about to re-run before running any of them.

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
        [ -z "$WANT" ] || usage_error "unexpected extra argument '$1'; this script takes one version and forces the whole shipped ladder"
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

# THE CROSS-CHECK. Both sides named, both values printed: an operator who is
# told only "wrong version" learns nothing about which of the two beliefs — the
# one they typed, or the kit they are standing in — is the mistaken one.
if [ "$WANT_NORM" != "$KIT_NORM" ]; then
    warn "REFUSING: you asked to force the $WANT_NORM migrations, but this kit's ladder"
    warn "tops out at $KIT_NORM."
    warn "  compared: $WANT_NORM  (from the argument '$WANT')"
    warn "   against: $KIT_NORM  (the newest target in $LEDGER)"
    warn "one of those is not what you think it is: either this is not the kit for the"
    warn "release you mean, or the release you mean has no migration in it. Forcing"
    warn "anyway would run $KIT_NORM's rungs while reporting a $WANT_NORM upgrade."
    warn "unpack the kit for the release you are moving to, and re-run it from there."
    warn "nothing has been touched — no migration ran, and nothing was installed."
    exit 64
fi

# ---------------------------------------------------------------------------
# SAY WHAT IS ABOUT TO BE RE-RUN, BEFORE RUNNING IT.
# ---------------------------------------------------------------------------
say "forcing the $KIT_NORM state migrations from $RUNNER."
say "this is the OVERRIDE, not the upgrade: install.sh places the binaries and"
say "walks this same ladder gated. nothing here installs anything."
say ""
say "every rung in this kit will be re-run, including any whose receipt says it"
say "already completed here:"
printf '%s\n' "$ROWS" | while read -r _v _s; do
    [ -n "$_s" ] || continue
    say "  $_s (target $_v)"
done
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
sh "$RUNNER" --installed-version 0.0.0 --rerun-recorded
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
    say "the migrations ran (exit 2). This runner stops no service, so there is"
    say "nothing here for you to restart."
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
