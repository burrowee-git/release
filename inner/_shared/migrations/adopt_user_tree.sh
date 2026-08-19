#!/bin/sh
# _shared/migrations/adopt_user_tree.sh — adopt this host's existing enrolled
# tree into the tree(s) this component's daemon actually reads.
# Target version 0.2.0 (see the component's migrations/ledger).
#
# ONE SOURCE: THE RUNNING USER'S HOME. ~<running user>/.burrowee/<comp>, and
# there is no second candidate.
#
# It PROVABLY holding identity/relay_ed.key is "adopt it"; it provably holding
# none is "nothing to adopt"; not being able to SEE is "still needed".
#
# The running user is $SUDO_USER when set, $HOME on an unprivileged run, and
# NOBODY under a root login shell — where this REFUSES and names $ADOPT_FROM
# rather than falling back to root's home. That fallback is not a hypothetical
# risk: root's home used to be the FIRST candidate here, and on 2026-08-19 it
# took an edge node down. See the SOURCE SELECTION block below for the whole
# account of it.
#
# $ADOPT_FROM overrides the selection entirely.
#
# ONE SOURCE ENTIRELY, NEVER GAP-FILLED: two enrolled trees can belong to two
# different edges, and taking the identity from one and the bridge key from the
# other yields a host that is neither — a mixture no re-run can undo. With one
# candidate there is no longer a second tree to take anything from.
#
# TWO DESTINATIONS where the component declares them. A `system`-scheme
# component has a CONFIG tree ($COMP_HOME) and a DATA tree ($COMP_DATA); the cli
# does the placing, this rung only names the roots. Every other scheme answers
# with one directory for both, so nothing about them changes.
#
# ONE STEP IN THE LADDER. run.sh owns the version gate, the receipt and the
# ordering; this script owns the stop and the call that does the copy. Never
# invoked directly by install.sh or update.sh — always through run.sh, so a host
# that skipped releases runs every intermediate rung in order.
#
# WHAT WENT WRONG WITHOUT IT. 0.2.0 moved the edge daemon to root, so it read
# $ROOT_HOME/.burrowee/edge while an already-enrolled host's identity, console
# pin, config and certs stayed in the operator's ~/.burrowee/edge. (Edge has
# since made the system-roots split the spec always specified, which is why the
# destination below is $COMP_HOME/$COMP_DATA rather than root's home — the first
# cut of this rung pointed at /root/.burrowee/edge, the wrong destination, and
# was withdrawn before promotion.) The gateway
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
#               IT ANSWERS "STILL NEEDED" WHENEVER IT CANNOT TELL. Every piece of
#               evidence sits in a 0700 tree — the destination is root-owned, the
#               source is the running user's — and this probe is reached
#               unprivileged all the
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
        SYS_CONFIG_ROOT="${SYS_CONFIG_ROOT:-/usr/local/etc/burrowee}"
        case "${COMP_HOME_SCHEME:-user}" in
        system) COMP_HOME="$SYS_CONFIG_ROOT/$COMP" ;;
        root)   COMP_HOME="$(root_home)/.burrowee/$COMP" ;;
        *)      COMP_HOME="$(operator_home)/.burrowee/$COMP" ;;
        esac
    fi
fi

# $COMP_DATA is the DATA tree. run.sh resolves it and hands it down; a direct
# invocation resolves it the same way, and every scheme but `system` answers with
# $COMP_HOME so a component that never split reads exactly as it did before.
if [ -z "${COMP_DATA:-}" ]; then
    SYS_DATA_ROOT="${SYS_DATA_ROOT:-/usr/local/var/burrowee}"
    case "${COMP_HOME_SCHEME:-user}" in
    system) COMP_DATA="$SYS_DATA_ROOT/$COMP" ;;
    *)      COMP_DATA="$COMP_HOME" ;;
    esac
fi

BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}"
SUDO="${SUDO:-sudo}"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"

DST="$COMP_HOME"
DST_DATA="$COMP_DATA"

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
# canon <path> — the path as the filesystem sees it, or unchanged when it does
# not exist. Used only for comparing two trees for identity.
# ---------------------------------------------------------------------------
canon() { (cd "$1" 2>/dev/null && pwd) || echo "$1"; }

# is_a_destination <dir> — dir IS one of this component's own trees.
#
# This is the guard that makes a SHARED rung inert for a component whose daemon
# never moved. tools/payload.sh stages every shared script into every kit that
# takes the shared ladder, so this file ships inside cli's kit too; cli's ledger
# does not name it, and if a future one ever did, cli is a `user`-scheme component
# whose tree IS the operator's, so there is nothing to adopt and this says so
# instead of copying a tree onto itself.
# ---------------------------------------------------------------------------
is_a_destination() {
    _iad="$(canon "$1")"
    [ "$_iad" = "$(canon "$DST")" ] || [ "$_iad" = "$(canon "$DST_DATA")" ]
}

# ---------------------------------------------------------------------------
# tree_is_readable_here <dir> — whether THIS process could have seen an identity
# in dir if one were there, i.e. whether a negative answer is evidence or
# blindness.
#
# "Yes" for the two cases that need no root: no tree at all (nothing to be blind
# to), and an identity/ this caller can traverse. An absent tree is provable only
# when its parent is traversable — a locked parent hides the whole question.
# ---------------------------------------------------------------------------
tree_is_readable_here() {
    if [ ! -d "$1" ]; then
        _tr_parent="$(dirname "$1")"
        if [ -d "$_tr_parent" ] && [ ! -x "$_tr_parent" ]; then return 1; fi
        return 0
    fi
    [ -x "$1" ] || return 1
    [ -d "$1/identity" ] || return 0
    [ -x "$1/identity" ]
}

# ---------------------------------------------------------------------------
# holds_identity <dir> — 0 it PROVABLY holds one · 1 it PROVABLY holds none ·
# 2 cannot tell from here.
#
# Three answers, not two, because the two negative ones lead to opposite
# decisions: a tree that provably holds nothing is a tree with nothing to adopt,
# and a tree we could not read is a tree that might hold this host's entire
# identity. Collapsing them is what would skip the rung on the hosts it exists
# for — the per-user tree is 0700 and owned by an account this probe often is
# not.
# ---------------------------------------------------------------------------
holds_identity() {
    [ -s "$1/$ID_REL" ] && return 0
    tree_is_readable_here "$1" || return 2
    return 1
}

# ---------------------------------------------------------------------------
# SOURCE SELECTION — THE RUNNING USER'S HOME, AND NOTHING ELSE.
#
# There is ONE candidate. There used to be two, root's home first, and that
# precedence took a production edge down on 2026-08-19.
#
# WHY ROOT'S HOME WAS EVER FIRST. The reasoning was "root's tree is the one a
# 0.2.0 daemon has been reading and writing since the collapse, so it is
# strictly newer than the pre-collapse ancestor it was made from". That
# reasoning assumed root's tree got there BY MIGRATION. On admin-kr it got there
# by a manual copy, and two days of a crash-looping daemon then reduced it to a
# single line:
#
#     adopted  /usr/local/etc/burrowee/edge/config   lan_listen=127.0.0.1:9448
#     real     /home/ubuntu/.burrowee/edge/config    tls_listen=127.0.0.1:9443
#                                                    lan_listen=127.0.0.1:9448
#                                                    serve_mode=frontier
#                                                    allow_push_update=true
#                                                    host_fqdn=admin-kr.faranow.com
#
# NEWEST AND RICHEST DIVERGE EXACTLY WHEN THE NEWER TREE IS A DAEMON-WRITTEN
# STUB. The identity, the bridge keys and the receipts came across correctly;
# only the config was degraded — and with no tls_listen the daemon tried to bind
# privileged :443 unprivileged and crash-looped. The copy never overwrites, so
# no re-run could heal it.
#
# THE RULE NOW. The source is the tree of the account this run is being made on
# behalf of, resolved by lib_paths.sh's running_user_home:
#
#   * $SUDO_USER when set — the account that invoked sudo, i.e. the one whose
#     tree holds the pre-collapse install.
#   * $HOME on an unprivileged run, where this IS that account's own shell.
#   * NOTHING under a root login shell ($SUDO_USER unset, euid 0). There is no
#     running user, so there is no source, and this REFUSES naming $ADOPT_FROM
#     rather than quietly taking root's home. The quiet fallback is the defect.
#
# $ADOPT_FROM still overrides the whole selection — the operator has named the
# tree, and a rung that then went looking for a "better" one would be
# second-guessing the person recovering the host.
#
# ONE SOURCE ENTIRELY, NEVER GAP-FILLED, still holds and is now trivially true:
# with one candidate there is no second tree to take the bridge key from. That
# mixture — host A's node identity presenting host B's bridge key — is what the
# rule was written against, and removing the second candidate removes the way in.
# ---------------------------------------------------------------------------
SRC=""              # the tree this run will adopt from ("" = none selected)
SRC_BLIND=0         # 1 = the candidate could not be read at all
NO_RUNNING_USER=0   # 1 = nothing named a running user, so there is no candidate

if [ -n "${ADOPT_FROM:-}" ]; then
    SRC="$ADOPT_FROM"
elif _run_home="$(running_user_home)" && [ -n "$_run_home" ]; then
    _cand="$_run_home/.burrowee/$COMP"
    # THE GUARD THAT MAKES A SHARED RUNG INERT for a component whose daemon never
    # moved: cli is a `user`-scheme component whose tree IS the running user's,
    # so it is skipped as a CANDIDATE rather than selected and then rejected.
    if ! is_a_destination "$_cand"; then
        # `if`, not a bare call followed by `case $?`: this script runs under
        # `set -e`, and a bare command that exits 1 or 2 ends the run. That is
        # not hypothetical — it is how the first cut of this selection aborted
        # the whole rung the moment the candidate held no identity, with no
        # output at all.
        if holds_identity "$_cand"; then
            _hi=0
        else
            _hi=$?
        fi
        case "$_hi" in
        0) SRC="$_cand" ;;
        2) SRC_BLIND=1 ;;
        esac
    fi
else
    NO_RUNNING_USER=1
fi

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
    tree_is_readable_here "$DST" && return 1
    elevate test -s "$DST/$ID_REL" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# nothing_to_adopt — no candidate provably holds an identity, AND none of them
# was merely unreadable.
#
# The blindness clause is the whole asymmetry: "I cannot read
# /home/ubuntu/.burrowee/edge/identity" and "there is nothing in it" are what a
# bare `-s` cannot tell apart, and reading the second as the first would skip the
# rung on the very host it was written for.
# ---------------------------------------------------------------------------
nothing_to_adopt() {
    [ -n "$SRC" ] && return 1
    [ "$SRC_BLIND" = 1 ] && return 1
    # No running user is not "nothing to adopt" either — it is "I was not told
    # which tree to look at". Answering the first would skip the rung silently
    # on a root login shell, which is a host that may well have state to carry.
    [ "$NO_RUNNING_USER" = 1 ] && return 1
    return 0
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
if [ -n "$SRC" ] && is_a_destination "$SRC"; then
    say "$SRC is one of this component's own trees — there is nothing to adopt."
    say "if this host DOES have a separate tree, name it:"
    say "  ADOPT_FROM=/home/<user>/.burrowee/$COMP sh $0"
    exit 0
fi

if nothing_to_adopt; then
    say "no enrolled identity in $(running_user_home)/.burrowee/$COMP — nothing to adopt."
    say "(the identity is the evidence: a tree without one is an unenrolled tree, and"
    say "the daemon mints on first start.)"
    say "if the state is in a third tree, name it:"
    say "  ADOPT_FROM=/path/to/.burrowee/$COMP sh $0"
    exit 0
fi

# NO RUNNING USER — REFUSE, AND NAME THE ESCAPE HATCH. This is the branch the
# whole selection was rewritten around: root's home is one keystroke away and it
# is the wrong answer, so the rung stops rather than substituting it.
if [ "$NO_RUNNING_USER" = 1 ]; then
    warn "REFUSING: this is a root login shell — \$SUDO_USER is unset, so no account"
    warn "invoked this run and there is no running user whose tree could be adopted."
    warn "root's own home is NOT the fallback: on a production node it held a copy a"
    warn "crash-looping daemon had cut down to one line, and adopting it published"
    warn "that stub into a destination the copy can never overwrite."
    warn "name the tree and re-run:"
    warn "  ADOPT_FROM=/home/<user>/.burrowee/$COMP sh $0"
    warn "nothing has been stopped and nothing has been copied."
    exit 1
fi

if [ -z "$SRC" ]; then
    warn "the running user's tree could not be read, so this rung cannot say whether"
    warn "there is anything to adopt. Re-run as root, or name the tree:"
    warn "  ADOPT_FROM=/path/to/.burrowee/$COMP sh $0"
    warn "nothing has been stopped and nothing has been copied."
    exit 1
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
    for _rt in "$DST_DATA" "$DST" "$SRC"; do
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
elif [ "$DST_DATA" != "$COMP_HOME" ]; then
    say "adopted $SRC → $COMP_HOME (config) + $DST_DATA (state)"
else
    say "adopted $SRC → $COMP_HOME"
fi
say "the per-user tree is left intact; remove it by hand once the $COMP is healthy"
say "burrowee-$COMP is STOPPED — the caller starts it (see run.sh's exit 2)"
