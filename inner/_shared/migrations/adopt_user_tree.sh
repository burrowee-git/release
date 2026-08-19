#!/bin/sh
# _shared/migrations/adopt_user_tree.sh — adopt the pre-collapse PER-USER tree
# into the tree this component's root-scheme daemon actually reads.
# Target version 0.2.0 (see the component's migrations/ledger).
#
# ONE STEP IN THE LADDER. run.sh owns the version gate, the receipt and the
# ordering; this script owns the stop and the call that does the copy. Never
# invoked directly by install.sh or update.sh — always through run.sh, so a host
# that skipped releases runs every intermediate rung in order.
#
# WHAT WENT WRONG WITHOUT IT. 0.2.0 moved the edge daemon to root, so it reads
# $ROOT_HOME/.burrowee/edge while an already-enrolled host's identity, console
# pin, config and certs stayed in the operator's ~/.burrowee/edge. The gateway
# got migrations/v1_to_v2.sh for exactly this; edge's ladder held the
# stale-binary sweep and nothing else, so nothing ever moved them. Observed on a
# production node, 2026-08-19, at v0.2.0.2026.08.19.78a2c91a:
#
#     edge: no manifest applied yet — polling for console-signed config
#     relay: console-carrier: dial error: unknown-relay
#     edge: no manifest within the poll window — falling back to frontier (:443)
#     …nothing to route — host_fqdn not set in /root/.burrowee/edge/config
#     burrowee-edge: listen tcp :443: bind: address already in use
#
# — a crash loop, and three customer domains dark for about 35 hours. Every line
# after the first is a consequence of the tree being empty.
#
# MODES
#   --applies   exit 0 if this host still needs the adoption. run.sh calls this
#               ONLY when no version is recorded, and it has no veto (see run.sh's
#               header on --installed-version).
#
#               IT ANSWERS "STILL NEEDED" WHENEVER IT CANNOT TELL. Both pieces of
#               evidence sit in 0700 trees — the destination is root's, the source
#               is the operator's — and this probe is reached unprivileged all the
#               time, because install.sh and update.sh run the runner as the
#               invoking user and elevate the individual steps. A blind probe that
#               guessed "already done" would silently skip the migration on the
#               exact hosts it exists for, and the cost of the other direction is
#               a rung that runs, copies nothing (the copy never overwrites) and
#               leaves a receipt. So a readable YES is yes, a readable ABSENCE is
#               no, and everything else is asked of root read-only; with root
#               unreachable the answer stays "still needed".
#   (no args)   perform the adoption.
#
# IT STOPS THE DAEMON, AND IT IS THE FIRST RUNG ON THIS RUNNER THAT DOES. run.sh's
# header used to promise that nothing on its ladders needed a stop and told the
# rung that changed that to say so; this is that rung, and the promise has been
# rewritten around $SERVICE_STOP_RUNGS in the component's migrations/component.conf.
#
# THE MOVING TARGET IS THE DESTINATION, NOT THE SOURCE. The per-user tree is not
# being written any more — that daemon is gone. The ROOT one is: on the observed
# host the daemon was crash-looping against it, and burrowee-edge MINTS what it
# cannot find. relay.LoadOrInitIdentity generates and persists
# identity/relay_ed.key on first start, loadOrInitBridgeIdentity does the same for
# bridge/bridge_ed.key, and ensureLanListenPersisted writes into config. Copy
# underneath that and the adoption races a daemon that is filling the destination
# with fresh keys — and because the copy never overwrites, the freshly minted ones
# WIN. The host then comes up with an identity the console has never seen and a
# bridge key every authorized peer rejects, out of a migration that reported
# success. Stopping first is what makes the destination hold still.
#
# THE COPY IS NOT REIMPLEMENTED HERE. `burrowee-<comp>-cli migrate` refuses a
# truncated or unreadable source credential before copying anything, publishes
# each file by atomic rename through a unique scratch name, never overwrites a
# destination, and carries an ENUMERATED set rather than a glob — the receipts
# directory, the version anchor and hundreds of megabytes of logs are all things
# a `cp -a` would have taken. The never-overwrite property is exactly why a shell
# rewrite would be a bad trade: a half-written relay_ed.key published once under
# its final name can never be healed by re-running.
#
# COPY, NEVER MOVE. The per-user tree is left in place, so an adoption that goes
# wrong is recovered by pointing the old unit back at it. Enforced on the Go side.
#
# IDEMPOTENT. A second run finds every destination present, copies nothing, and
# says so — which is what makes it safe for install.sh, for update.sh, and for an
# operator forcing the ladder with upgrade.sh.
set -eu

HERE="$(dirname "$0")"

say()  { echo "adopt_user_tree: $*"; }
warn() { echo "adopt_user_tree: $*" >&2; }

# lib_paths.sh is the ONE definition of "the operator's home" and "root's home".
# A second copy of the $SUDO_USER rule here is how a sweep once aimed itself at
# /root and reported a clean no-op on a host whose state was all in /home.
if [ ! -f "$HERE/lib_paths.sh" ]; then
    warn "$HERE/lib_paths.sh is missing — THIS RELEASE IS INCOMPLETE."
    warn "this rung resolves the operator's home through it and will not guess."
    warn "refusing rather than exiting 0, which would earn a receipt for work that"
    warn "never happened."
    exit 1
fi
# shellcheck source=lib_paths.sh
. "$HERE/lib_paths.sh"

# $COMP and $COMP_HOME come from run.sh, which resolves both before it runs any
# rung. component.conf is consulted only when they did not — a direct invocation,
# which the header discourages — so the probe answers about the same tree the
# runner would have named rather than aborting under `set -u`.
if [ -z "${COMP:-}" ] || [ -z "${COMP_HOME:-}" ]; then
    if [ -f "$HERE/component.conf" ]; then
        # shellcheck source=/dev/null
        . "$HERE/component.conf"
    fi
    if [ -z "${COMP:-}" ]; then
        warn "no \$COMP and no component.conf — cannot say which component this is."
        exit 1
    fi
    if [ -z "${COMP_HOME:-}" ]; then
        case "${COMP_HOME_SCHEME:-user}" in
        root) COMP_HOME="$(root_home)/.burrowee/$COMP" ;;
        *)    COMP_HOME="$(operator_home)/.burrowee/$COMP" ;;
        esac
    fi
fi

BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}"
SUDO="${SUDO:-sudo}"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"

DST="$COMP_HOME"
# ADOPT_FROM is the operator's escape hatch, and it exists because of a real gap:
# operator_home reads $SUDO_USER first and $HOME second, so a run started from a
# ROOT LOGIN SHELL (rather than through sudo) has no way to name the account whose
# tree holds the state — $HOME is root's, the two trees come out equal, and the
# rung correctly reports there is nothing to adopt. The message below says so and
# names this variable rather than leaving an operator mid-incident to conclude the
# rung is broken.
SRC="${ADOPT_FROM:-$(operator_home)/.burrowee/$COMP}"

# The identity is the evidence for BOTH questions — is there anything to adopt,
# and has it already been adopted — because it is the one file whose presence
# means "this tree is a paired edge". Everything else in the carried set is
# config beside it.
ID_REL="identity/relay_ed.key"

# The cli that owns the copy. Same $BIN_DIR the runner resolved and the installers
# place into, so the binary probed below and the binary run further down are the
# same file.
CLI="$BIN_DIR/burrowee-$COMP-cli"

elevate() {
    if [ "$(id -u)" = 0 ]; then "$@"; else $SUDO "$@"; fi
}

# ---------------------------------------------------------------------------
# same_tree — the source and the destination are one directory.
#
# This is the guard that makes a SHARED rung inert for a component whose daemon
# never moved. tools/payload.sh stages every shared script into every kit that
# takes the shared ladder, so this file ships inside cli's kit too; cli's ledger
# does not name it, and if a future one ever did, cli is a `user`-scheme component
# whose tree IS the operator's, so there is nothing to adopt and this says so
# instead of copying a tree onto itself.
# ---------------------------------------------------------------------------
same_tree() {
    [ "$(cd "$SRC" 2>/dev/null && pwd || echo "$SRC")" = "$(cd "$DST" 2>/dev/null && pwd || echo "$DST")" ]
}

# ---------------------------------------------------------------------------
# already_adopted — the DESTINATION provably holds the identity this rung exists
# to put there.
#
# A readable non-empty key is a yes. A readable ABSENCE — we could have seen it
# and it is not there — is a no. Everything else is "cannot answer
# unprivileged", and it is asked of root, READ-ONLY. When root is unreachable
# (`sudo -n` on the console-push path, no terminal to prompt on) the elevated
# read fails and the answer is "not provably adopted", which sends --applies
# toward "still needed" — the same fail-safe direction run.sh takes for a
# receipt it cannot read.
#
# The elevated read is not an escalation of this rung's privilege model: the
# real work below is `elevate "$CLI" migrate`, so running as root is the whole
# point of the rung rather than a new capability.
# ---------------------------------------------------------------------------
already_adopted() {
    [ -s "$DST/$ID_REL" ] && return 0
    dest_is_readable_here && return 1
    elevate test -s "$DST/$ID_REL" >/dev/null 2>&1
}

# dest_is_readable_here — whether THIS process could have seen the key above if
# it were there, i.e. whether the negative answer is evidence or blindness.
#
# "Yes" for the two cases that need no root: no destination tree at all (nothing
# to be blind to, and asking sudo would put a password prompt in front of every
# host that has never migrated), and an identity/ this caller can traverse.
dest_is_readable_here() {
    [ -d "$DST" ] || return 0
    [ -x "$DST" ] || return 1
    [ -d "$DST/identity" ] || return 0
    [ -x "$DST/identity" ]
}

# ---------------------------------------------------------------------------
# nothing_to_adopt — the SOURCE provably holds no identity.
#
# THE SAME ASYMMETRY, FACING THE OTHER WAY, and it is not symmetry for its own
# sake: the per-user tree is 0700 and owned by an account this probe may not be,
# so "I cannot read /home/ubuntu/.burrowee/edge/identity" and "there is nothing
# in it" are the answers a bare `-s` cannot tell apart. Reading the second as the
# first is what would skip the rung on the very host it was written for.
# ---------------------------------------------------------------------------
nothing_to_adopt() {
    [ -s "$SRC/$ID_REL" ] && return 1
    src_is_readable_here || return 1
    return 0
}

src_is_readable_here() {
    if [ ! -d "$SRC" ]; then
        # An absent source is provable only when we could have seen it: a
        # non-traversable parent hides the whole question.
        _sr_parent="$(dirname "$SRC")"
        if [ -d "$_sr_parent" ] && [ ! -x "$_sr_parent" ]; then return 1; fi
        return 0
    fi
    [ -x "$SRC" ] || return 1
    [ -d "$SRC/identity" ] || return 0
    [ -x "$SRC/identity" ]
}

# ---------------------------------------------------------------------------
# --applies: does this host STILL need the adoption?
#
# Three answers make it "no", and they are not the same reason:
#
#   * one tree. There is no per-user tree distinct from the component's, so
#     there is nothing this rung could move.
#   * already carried over. The destination holds an identity, so this rung has
#     run (or the host was born on 0.2.x). Saying "yes" here would be the
#     dishonesty the gateway's probe had for a while: the copy never moves, so
#     on EVERY adopted host the per-user tree survives, and a probe that keyed
#     only on the source would answer "still needed" forever.
#   * nothing to carry. An unenrolled per-user tree has no identity; the daemon
#     mints one on first start, and claiming a migration applies would only
#     leave a misleading receipt.
#
# Anything else — including every form of "I could not see" — is a yes.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--applies" ]; then
    if same_tree; then exit 1; fi
    if already_adopted; then exit 1; fi
    if nothing_to_adopt; then exit 1; fi
    exit 0
fi

if [ "${1:-}" != "" ]; then
    warn "unknown argument '$1' (expected --applies or none)"
    exit 2
fi

# ---------------------------------------------------------------------------
# THE REAL RUN
# ---------------------------------------------------------------------------
if same_tree; then
    say "$SRC and $COMP_HOME are the same directory — there is no separate per-user"
    say "tree to adopt on this host."
    say "if this host DOES have one and you started this from a root login shell,"
    say "\$SUDO_USER is unset and \$HOME is root's, so it cannot be named from here."
    say "re-run through sudo from the operator's account, or name it:"
    say "  ADOPT_FROM=/home/<user>/.burrowee/$COMP sh $0"
    exit 0
fi

if nothing_to_adopt; then
    say "no enrolled identity at $SRC — nothing to adopt."
    say "(the identity is the evidence: a tree without one is an unenrolled tree, and"
    say "the daemon mints on first start.)"
    exit 0
fi

# EVERY PRE-FLIGHT RUNS BEFORE THE STOP. Discovering a missing cli after the
# daemon is down turns a refusal that cost nothing into an outage, on a host that
# is mid-upgrade with freshly swapped binaries.
if [ ! -x "$CLI" ]; then
    warn "$CLI is missing — cannot adopt $SRC."
    warn "nothing has been stopped and nothing has been copied."
    exit 1
fi
if ! "$CLI" migrate --help >/dev/null 2>&1; then
    warn "$CLI does not understand \`migrate\` — it predates this rung."
    warn "nothing has been stopped and nothing has been copied. Re-run the installer,"
    warn "which places the current cli before it walks the ladder."
    exit 1
fi
if ! elevate true >/dev/null 2>&1; then
    warn "this run cannot reach root ('$SUDO' did not run for us), and the adoption"
    warn "writes into $COMP_HOME as root."
    warn "nothing has been stopped and nothing has been copied. Re-run as root."
    exit 1
fi

# ---------------------------------------------------------------------------
# argv_is_comp — whether a process's argv[0] IS the component daemon.
#
# `ps -o comm=` is NOT the alternative it looks like: on Linux comm is the
# kernel's task name, capped at 15 characters, so "burrowee-gateway" arrives
# truncated and matches nothing. -o args= gives the full command line.
#
# The four patterns accept the name only at the end of a path (or bare) and only
# at end-of-line or before a space, which is what keeps burrowee-edge-updater and
# burrowee-edge-cli — longer basenames — from matching. A later ARGUMENT ending in
# /burrowee-edge would also match; argv[0] cannot be isolated from a
# space-separated line, and erring toward "alive" is the safe direction here,
# because it refuses to copy rather than copying under a running daemon.
# ---------------------------------------------------------------------------
argv_is_comp() {
    case "$1" in
    "burrowee-$COMP" | */"burrowee-$COMP") return 0 ;;
    "burrowee-$COMP "* | *"/burrowee-$COMP "*) return 0 ;;
    esac
    return 1
}

# comp_alive — whether the daemon is still running, from the pid it records in
# running.json. This is the POST-CONDITION on the stop: every supervisor rung
# below is best-effort, and a host with no supervisor at all (a container) has
# none that can work — so "I asked it to stop" is not evidence that it did. The
# pid is believed only when its argv[0] IS the daemon, so a stale or recycled pid
# never counts.
comp_alive() {
    for _rt in "$DST" "$SRC"; do
        [ -f "$_rt/running.json" ] || continue
        _pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_rt/running.json" 2>/dev/null | head -n 1)
        [ -n "$_pid" ] || continue
        if argv_is_comp "$(ps -o args= -p "$_pid" 2>/dev/null)"; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# stop_component — stop the daemon under every supervisor topology it may have
# been installed with, then WAIT for it to actually exit.
#
# ONLY THE DAEMON, NEVER THE UPDATER. update.sh runs UNDER burrowee-<comp>-updater,
# so booting that out would kill the process running this script.
#
# The legacy org.* labels and the systemd --user unit are here because a host
# arriving at this rung is by definition one that has not converged: it may still
# be running whatever a pre-0.2.0 install laid down.
# ---------------------------------------------------------------------------
stop_component() {
    case "$(uname -s)" in
    Darwin)
        for _label in "org.burrowee.$COMP" "com.burrowee.$COMP"; do
            "$LAUNCHCTL" bootout "gui/$(id -u)/$_label" 2>/dev/null || true
            elevate "$LAUNCHCTL" bootout "system/$_label" 2>/dev/null || true
        done
        ;;
    *)
        "$SYSTEMCTL" --user stop "burrowee-$COMP.service" 2>/dev/null || true
        elevate "$SYSTEMCTL" stop "burrowee-$COMP.service" 2>/dev/null || true
        ;;
    esac

    # A generous ceiling on the graceful path without hanging an installer for
    # minutes. The seam exists so a test does not have to wait it out.
    _ceiling="${BURROWEE_MIGRATE_STOP_TIMEOUT:-30}"
    _waited=0
    while comp_alive && [ "$_waited" -lt "$_ceiling" ]; do
        sleep 1
        _waited=$((_waited + 1))
    done
    if comp_alive; then
        warn "burrowee-$COMP is still running after $_waited s — REFUSING to copy into"
        warn "$COMP_HOME while a daemon is writing to it: it mints an identity and a"
        warn "bridge key when it cannot find them, the copy never overwrites, and the"
        warn "minted ones would win."
        warn "stop it and re-run:"
        warn "  $CLI service restart   (or stop the service by hand)"
        return 1
    fi
}

# Asked BEFORE the copy, because afterwards the answer is always "yes" and the
# question — did this run actually adopt anything? — becomes unanswerable. The
# cli prints its own per-file report; this decides which summary line is honest.
_dest_had_identity=0
if already_adopted; then _dest_had_identity=1; fi

say "stopping burrowee-$COMP so $COMP_HOME holds still while it is written"
if ! stop_component; then exit 1; fi

if ! elevate "$CLI" migrate --from "$SRC" --home "$(dirname "$COMP_HOME")"; then
    warn "migrate failed — $SRC is untouched."
    warn "burrowee-$COMP is STOPPED. re-run by hand once the cause is fixed:"
    warn "  sudo $CLI migrate --from $SRC --home $(dirname "$COMP_HOME")"
    warn "then start the service."
    exit 1
fi

if [ "$_dest_had_identity" = 1 ]; then
    # "adopted" would be a lie here, and the lie has a cost: this is the exact
    # state an operator recovering from a mis-targeted adoption lands in, and a
    # success line sends them away believing the host changed.
    say "$COMP_HOME already held an identity before this run — the copy never"
    say "overwrites, so nothing of $SRC's identity replaced it. See the per-file"
    say "report above for what was and was not taken."
else
    say "adopted $SRC → $COMP_HOME"
fi
say "the per-user tree is left intact; remove it by hand once the $COMP is healthy"
say "burrowee-$COMP is STOPPED — the caller starts it (see run.sh's exit 2)"
