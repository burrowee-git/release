#!/bin/sh
# _shared/migrations/run.sh — the migration runner (POSIX sh).
#
# ONE RUNNER, STAGED INTO EVERY KIT THAT NEEDS ONE. This file is authored once,
# here in the release repo, and tools/payload.sh copies it into each
# component's release zip as migrations/run.sh. There is no second checked-in
# copy to drift: what edge ships and what cli ships are the same bytes.
#
# The gateway is the one component that does NOT take this runner. Its
# migrations/run.sh lives in the gateway repo, has shipped, and does three
# things no other component needs — it stops a live daemon so a SQLite store is
# at rest while it is copied, it pre-flights `burrowee-gateway-cli migrate`, and
# it resolves which ACCOUNT's pre-split tree holds the host's identity. Folding
# it in would mean editing a shipped runner and re-pointing its suite; the
# reason it stays separate is written down rather than left to be rediscovered.
# See the header of gateway/migrations/run.sh.
#
# THE LADDER
# Every migration ever written keeps shipping, and each one declares the version
# it upgrades TO. The runner walks them in order and runs each whose gate fires:
#
#     installed 0.1.114  →  0.2.0 applies, 0.2.5 applies  →  both run, in order
#     installed 0.2.0    →  0.2.0 skipped, 0.2.5 applies  →  only 0.2.5 runs
#     installed 0.2.5    →  nothing applies               →  exit 0
#
# so a host may skip any number of releases and still arrive by the same path a
# host that upgraded one release at a time took. Adding a migration means adding
# ONE row to migrations/ledger plus the script; nothing else changes, and no
# existing migration is edited (editing one changes history for hosts that have
# not run it yet).
#
# THE LEDGER IS A DATA FILE, not a here-string inside this script, and that is
# the one structural difference from the gateway's runner. This file is shared;
# the ledger is not — it is the component's own list, owned by the component's
# repo, so it cannot live inside a file every component receives identical
# copies of. migrations/ledger is APPEND-ONLY exactly as the gateway's
# MIGRATIONS= block is: never reorder it, never edit a shipped row.
#
# THE GATE is a numeric version comparison, not a glob: 0.10.0 is NEWER than
# 0.2.0 and must not re-run 0.2.0's migration. Only the first three fields are
# compared, so a release stamp's date/sha suffix
# (0.1.114.2026.08.04.be19c8b6) is ignored.
#
# EVERY RUNG SAYS WHAT IT DECIDED, and the ladder says so once more at the end.
# "Nothing applied" is never a bare silent exit 0: a host that genuinely needed
# nothing and a host skipped for a reason nobody had examined would otherwise
# produce identical output, and callers run this unconditionally on every
# install, so its output is the only place that distinction can live.
#
# THE RECEIPT IS SCOPED TO A TREE, NOT TO THE MACHINE. Every rung is about
# $COMP_HOME, and which directory that is depends on the scheme the component
# declares and on whose $HOME the caller ran under. So a receipt records the
# tree it was earned for, and ONLY a receipt naming THIS tree skips a rung. One
# naming a different tree, and one naming no tree at all, both settle nothing
# and the rung is decided on this tree's own evidence instead. A receipt that
# could answer for a tree it never saw is how one user's empty tree stranded
# another user's state.
#
# WHEN THE VERSION IS UNKNOWN the runner asks each migration directly:
# `<script> --applies` exits 0 if it should run. A host installed FRESH on 0.1.x
# has no version anchor at all, and only the migration itself knows how to
# recognise the state it migrates from. Garbage in the version file resolves to
# 0.0.0 and therefore APPLIES — the fail-safe direction is to migrate a host
# that may not need it (every migration is idempotent and receipted) rather than
# to skip one that does.
#
# FLAGS — an operator seam; --assume-below is also what migrations/upgrade.sh
# (the forcing entry) passes; install.sh and update.sh pass none of them:
#   --installed-version <v>  treat this host as having been on <v>, INSTEAD of
#                            reading the version anchor. STRICT: rungs targeting
#                            exactly <v> are skipped as done. See below.
#   --assume-below <line>    the INCLUSIVE FLOOR: assume this host is below
#                            <line>. The anchor is not read, and every rung
#                            targeting <line> or newer is selected; strictly
#                            older targets are done. Mutually exclusive with
#                            --installed-version — they answer opposite
#                            questions about rungs targeting the named line,
#                            which is exactly why the strict flag cannot express
#                            the floor (0.0.0 is not a floor, it is "everything").
#   --rerun-recorded         run a rung even though its receipt says it finished,
#                            AND declare the run FORCED to the rungs
#                            ($MIGRATION_FORCED=1 in their environment).
#   -h | --help | help       print the usage on stdout and exit 0.
#
# $MIGRATION_FORCED IS THE ONE THING THIS RUNNER SAYS ABOUT *WHY* A RUNG IS
# RUNNING, and it exists because "run this again" and "make the destination
# match the source" are the same operator intent for one rung on this ladder.
#
# The adoption never overwrites a destination, and it takes one source entirely.
# Both rules are right. Their consequence is that a tree adopted from the WRONG
# source can never be COMPLETED by the tooling: every destination is already
# there, so a re-run skips every file. An operator reaching for upgrade.sh on
# such a host is not asking for the same no-op a second time — they are saying
# the running user's tree is authoritative. So --rerun-recorded is passed down,
# and adopt_user_tree.sh turns it into `migrate --force`, which snapshots both
# destination roots first and names every file it replaces.
#
# NOTHING ELSE ON THIS LADDER READS IT. A rung that does not care about being
# forced simply does not look at the variable, and its behaviour is unchanged.
# A bad flag or an unparseable version exits 64 (EX_USAGE), NOT 2: 2 already
# means "migrations ran", and a caller switches on it. A usage error that reused
# 2 would make a typo look like a completed migration.
#
# --installed-version EXISTS BECAUSE THE VERSION FILE OFTEN DOES NOT. On a host
# whose anchor was never written the numeric gate is inert and every rung falls
# through to its --applies probe — the exceptional path, taken as the norm. The
# flag is the way an operator says "this host was on 0.1.115, walk the ladder
# from there".
#
#   * It REPLACES the file, it does not merge with it: with the flag given the
#     anchor is not read at all, so what the ladder does is a function of what
#     the operator typed and nothing else.
#   * It is VALIDATED before anything is copied or removed (valid_version). The
#     file may hold garbage and fail safe to 0.0.0; a value a human typed may
#     not, because "0.1.x" would silently resolve to 0.1.0 and select a
#     different set of rungs instead of erroring.
#   * It does NOT touch the receipt. A rung that already completed here is still
#     skipped — the flag changes where the ladder STARTS, not whether finished
#     work is redone. --rerun-recorded is the separate opt-in for that.
#   * The --applies probe is still consulted, but only to REPORT a disagreement:
#     the named version selects the rungs, exactly as a recorded version would.
#     The probe does not get a veto, because every probe in the tree was written
#     against the documented contract "run.sh calls this ONLY when no version is
#     recorded". Repurposing it as a second gate would silently change what
#     shipped migrations mean.
#
# *** THIS RUNNER STOPS NOTHING. A RUNG MAY, AND IT SAYS WHICH ONE. ***
# The runner itself never stops or starts a service, and it never will: it does
# not know what any component's units are called. But the promise this header
# used to make — that NOTHING on its ladders needed a stop, so exit 2 could
# never leave a daemon down — stopped being true with adopt_user_tree.sh, and
# that rung is named here because the old text told whichever rung broke the
# promise to do exactly that.
#
# WHY THE STOP EXISTS. adopt_user_tree.sh copies a pre-collapse per-user tree
# into the tree a root-scheme daemon reads, and that daemon MINTS what it cannot
# find — an identity, a bridge key — while the copy never overwrites. Copying
# underneath it lets the minted keys win, and the host comes up with an identity
# the console has never seen out of a migration that reported success. See that
# rung's header.
#
# HOW THE RUNNER KNOWS, without learning about any component: the component
# DECLARES it, in migrations/component.conf.
#
#     SERVICE_STOP_RUNGS="adopt_user_tree.sh"
#
# The mechanism of stopping — unit names, launchd versus systemd, the pid probe —
# is component knowledge and stays inside the rung. What has to be visible HERE is
# only the fact that a stop is possible, because a contract discovered after the
# fact cannot be announced before it: the runner says "this run will stop the
# <comp> daemon" BEFORE the rung runs, and says the daemon is down afterwards, and
# upgrade.sh — which starts nothing — can tell an operator what they must start.
#
# A COMPONENT THAT DECLARES NONE IS UNAFFECTED, byte for byte. cli's
# component.conf sets no SERVICE_STOP_RUNGS, so the announcement below never
# fires on its ladder and its exit 2 means exactly what it always meant.
#
# EVERY NAME IN $SERVICE_STOP_RUNGS MUST BE IN THE LEDGER, and the run is refused
# when one is not. A typo there does not fail loudly on its own — it just means
# the announcement is never printed for the rung that does stop the daemon, which
# is the one failure mode a declaration can have that the code cannot.
#
# EXIT CODES — the whole contract with every caller:
#   0  nothing applied. Do whatever you would have done anyway. Nothing was
#      stopped.
#   1  refused or failed. Either nothing was touched (a pre-flight declined) or
#      a migration failed. Do NOT record a version. A rung that failed AFTER
#      stopping the daemon says so on stderr.
#   2  migrations ran. Record the version. IF one of the rungs that ran is named
#      in the component's $SERVICE_STOP_RUNGS, the component's daemon is STOPPED
#      and the caller must start it — the runner starts nothing. The last line of
#      output says which of the two happened, every time.
#   3  migrations ran, but at least one RECEIPT was not written. Do NOT record
#      the version. The receipt and the version anchor are the two gates on a
#      rung; with the receipt lost, recording the version closes the last one on
#      work nothing can prove finished. Leaving the version alone keeps the rung
#      re-runnable, and every migration is idempotent.
#  64  the command line was wrong (EX_USAGE). Nothing was evaluated. Deliberately
#      outside 0-3 so a typo can never be mistaken for one of the four states
#      above by a caller that switches on the code.
#
# NOTHING DESTRUCTIVE HAPPENS BEFORE THE PRE-FLIGHTS. The receipt-reachability
# probe runs before the first rung, because a rung that runs and then cannot be
# recorded is a rung that runs again forever; a refusal costs nothing.
#
# Env seams (production defaults shown; the installers and the test harness
# override them):
#   COMP_HOME                   the component CONFIG tree this ladder is about
#   COMP_DATA                   its DATA tree (`system` scheme; = COMP_HOME otherwise)
#   PREFIX / BIN_DIR            install prefix / bin dir (BIN_DIR wins)
#   ROOT_HOME                   root's home (the `root` COMP_HOME scheme)
#   SUDO                        elevation command (default "sudo")
#   BURROWEE_LEGACY_HOME_PARENTS  where to look for an account's home
#   LEDGER_FILE                 which ladder to walk (default $HERE/ledger — the
#                                serve ladder; the updater track points this at
#                                $HERE/updater-ledger instead)
set -eu

HERE="$(dirname "$0")"

say()  { echo "migrate: $*"; }
warn() { echo "migrate: $*" >&2; }

# ---------------------------------------------------------------------------
# THE COMPONENT'S OWN FACTS — migrations/component.conf, owned by the
# component's repo and staged into the kit beside this runner. A missing conf
# is fatal: this runner has no defaults to fall back on, and one that guessed a
# component name would write receipts into, and read a version anchor out of,
# a tree belonging to something else.
# ---------------------------------------------------------------------------
CONF="$HERE/component.conf"
if [ ! -f "$CONF" ]; then
    warn "$CONF is missing — THIS RELEASE IS INCOMPLETE."
    warn "the runner is shared by every component and carries no component defaults;"
    warn "component.conf is where the component name, its tree and its binary list"
    warn "come from. Refusing rather than guessing: nothing has been touched."
    exit 1
fi
# shellcheck source=/dev/null
. "$CONF"

COMP="${COMP:-}"
if [ -z "$COMP" ]; then
    warn "$CONF sets no COMP — THIS RELEASE IS INCOMPLETE. nothing has been touched."
    exit 1
fi

# shellcheck source=lib_paths.sh
. "$HERE/lib_paths.sh"

# ---------------------------------------------------------------------------
# SYS_CONFIG_ROOT / SYS_DATA_ROOT — the machine-owned parents a `system`-scheme
# component's two trees hang off. Seams for the test harness only; nothing on a
# real host sets them, and no component that is not `system` reads them.
# ---------------------------------------------------------------------------
SYS_CONFIG_ROOT="${SYS_CONFIG_ROOT:-/usr/local/etc/burrowee}"
SYS_DATA_ROOT="${SYS_DATA_ROOT:-/usr/local/var/burrowee}"

# ---------------------------------------------------------------------------
# $COMP_HOME / $COMP_DATA — the tree(s) this ladder is about.
#
# COMP_HOME_SCHEME says how to find them when the caller did not name them:
#
#   system the component is installed at the MACHINE level and has TWO trees
#          (edge, since the roots split): $COMP_HOME=$SYS_CONFIG_ROOT/$COMP
#          holds what cannot be reconstructed and gets backed up — the identity,
#          the console pin, the operator's config, the certs — and
#          $COMP_DATA=$SYS_DATA_ROOT/$COMP holds what the daemon rewrites while
#          it serves. Neither is derived from anybody's $HOME, which is the whole
#          point: a root daemon under launchd gets no $HOME and under systemd
#          gets whatever its unit carries.
#   root   the component's daemon runs as root and reads root's own home.
#          Root's home is /root on Linux and /var/root on macOS.
#   user   the component installs and runs per-user (cli), so the tree belongs
#          to the OPERATOR — $SUDO_USER's home when this was invoked through
#          sudo, and $HOME otherwise. Never a bare $HOME: under sudo that is
#          /root, a tree no per-user install ever wrote to, and a ladder aimed
#          there evaluates an empty directory and reports a clean no-op.
#
# ONE TREE FOR EVERY SCHEME BUT `system`. $COMP_DATA is set to $COMP_HOME there,
# so every rung can name it unconditionally and a component that never split —
# cli above all — behaves exactly as it did before this variable existed.
#
# An explicit $COMP_HOME from the caller always wins — the installers resolve
# it themselves and hand it down, so the runner and the installer can never
# disagree about which tree was migrated. For `system` the caller must name
# BOTH or NEITHER: pairing a named tree with a defaulted one is how a run comes
# to read config out of one install and write state into another, which is the
# defect the split exists to end rather than to relocate.
# ---------------------------------------------------------------------------
case "${COMP_HOME_SCHEME:-user}" in
system)
    if [ -n "${COMP_HOME:-}" ] && [ -z "${COMP_DATA:-}" ]; then
        warn "\$COMP_HOME was named ($COMP_HOME) but \$COMP_DATA was not, and $COMP has"
        warn "TWO machine-owned trees. Refusing rather than pairing the tree you named"
        warn "with a default one: that is how a run reads config from one install and"
        warn "writes state into another. Name both:"
        warn "  COMP_HOME=$COMP_HOME COMP_DATA=/path/to/var/burrowee/$COMP sh \$0"
        exit 1
    fi
    if [ -z "${COMP_HOME:-}" ] && [ -n "${COMP_DATA:-}" ]; then
        warn "\$COMP_DATA was named ($COMP_DATA) but \$COMP_HOME was not. Same refusal,"
        warn "facing the other way — name both."
        exit 1
    fi
    COMP_HOME="${COMP_HOME:-$SYS_CONFIG_ROOT/$COMP}"
    COMP_DATA="${COMP_DATA:-$SYS_DATA_ROOT/$COMP}"
    ;;
root)
    COMP_HOME="${COMP_HOME:-$(root_home)/.burrowee/$COMP}"
    COMP_DATA="$COMP_HOME"
    ;;
user)
    COMP_HOME="${COMP_HOME:-$(operator_home)/.burrowee/$COMP}"
    COMP_DATA="$COMP_HOME"
    ;;
*)
    warn "$CONF sets COMP_HOME_SCHEME='$COMP_HOME_SCHEME', which is none of 'system',"
    warn "'root' or 'user'. Refusing rather than guessing which tree to migrate."
    exit 1
    ;;
esac

# VERSION_FILE is the anchor's name INSIDE $COMP_HOME. It is per-component
# because the components already disagree: edge's installer has written
# `installed-version` since 0.1.x and the gateway writes `.installed-version`.
# Renaming either would orphan every anchor already on a host in the field.
VERSION_FILE="${VERSION_FILE:-.installed-version}"

BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}"
SUDO="${SUDO:-sudo}"
# Resolved HERE and exported to every rung by run_migration, for the same reason
# $SUDO is: a rung that inherited a different supervisor than the runner probed
# with would be acting on a different host. Only a stop-declaring rung reads
# them; a component with no such rung is unaffected by their presence.
LAUNCHCTL="${LAUNCHCTL:-launchctl}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"

# LEDGER_FILE — which ladder this run walks, INSIDE $HERE (this runner's own
# migrations/ directory). Defaults to the serve ladder, migrations/ledger, so
# every caller before Task 10 is unaffected. The UPDATER track is the one
# override: <comp>/updater.update.sh points this at migrations/updater-ledger
# — a second, separate ladder walked by this SAME runner, because it is the
# one script permitted to bounce the updater's own service (see
# adopt_updater_unit.sh's header). Never a second runner file: the gate logic,
# the receipt shape and the exit contract must not be free to drift between
# the two ladders a component can have.
LEDGER_FILE="${LEDGER_FILE:-$HERE/ledger}"

# SERVICE_STOP_RUNGS — the rungs on THIS component's ladder that leave its daemon
# stopped. Declared in migrations/component.conf; empty for every component that
# has none, which is the whole of what keeps their behaviour unchanged.
SERVICE_STOP_RUNGS="${SERVICE_STOP_RUNGS:-}"

# stops_the_service <script> — whether the component declared this rung as one
# that leaves the daemon down. Word-split, never a substring match: `case` on the
# whole string would let "adopt_user_tree.sh" be answered for by a declaration of
# "adopt_user_tree.sh.bak".
stops_the_service() {
    for _sts in $SERVICE_STOP_RUNGS; do
        [ "$_sts" = "$1" ] && return 0
    done
    return 1
}

# THE RECEIPTS LIVE IN THE TREE THEY ARE ABOUT. The gateway puts them in the
# single system config root and therefore has to record which tree each one was
# earned for; these runners have no system root at all, so the tree is the
# natural home — and the provenance line is written anyway, because "the
# receipt is in the tree" is a property of today's layout and the receipt has
# to keep saying what it witnessed if that ever changes.
#
# `migration-receipts`, NOT `migrations`. The installers keep a copy of the
# release's own migrations/ directory under $COMP_HOME so an offline reinstall
# can still migrate; a receipts directory sharing that name would have the
# shipped ladder and the record of what has been run writing into one directory,
# and the 0700 this one takes would then hide the scripts from the very
# reinstall that needs them.
RECEIPTS="$COMP_HOME/migration-receipts"

elevate() {
    if [ "$(id -u)" = 0 ]; then "$@"; else $SUDO "$@"; fi
}

# ---------------------------------------------------------------------------
# receipts_root_writable — whether this process can create the receipts
# directory without elevating, decided by walking UP to the nearest existing
# ancestor and reading its permissions. It creates nothing.
#
# The answer is normally yes: edge's ladder runs as root against root's own
# tree, and the cli's runs as the user against their own. Elevation is the
# exception (an operator running the edge ladder by hand as themselves), not
# the rule — which is why nothing here reaches for sudo before asking.
# ---------------------------------------------------------------------------
receipts_root_writable() {
    _rrw="$RECEIPTS"
    while [ ! -d "$_rrw" ]; do
        _rrw_p="$(dirname "$_rrw")"
        [ "$_rrw_p" != "$_rrw" ] || break
        _rrw="$_rrw_p"
    done
    [ -w "$_rrw" ]
}

# as_owner CMD… — run CMD directly when the receipts root is ours to write,
# through $SUDO when it is not. One decision point, so a read and the write it
# authorises can never be made by two different identities.
as_owner() {
    if receipts_root_writable; then "$@"; else elevate "$@"; fi
}

# ---------------------------------------------------------------------------
# THE COMMAND LINE
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
usage: sh $0 [--installed-version <version> | --assume-below <line>] [--rerun-recorded]

Runs every $COMP state migration this host has not reached yet, oldest first.
A no-op unless one applies, so it is safe to run unconditionally.

  --installed-version <version>
        The version this host was on, e.g. 0.1.115 (a leading "v" and a release
        stamp's trailing .date.sha are accepted). The ladder starts from it and
        \$COMP_HOME/$VERSION_FILE is NOT read. Use it when that file is absent
        or wrong. Must be MAJOR.MINOR.PATCH: an unparseable value is refused,
        never rounded down to 0.0.0. STRICT: "was on 0.2.0" means the 0.2.0
        rungs are done — a rung targeting exactly <version> is skipped. To make
        rungs targeting a line run AGAIN, name that line with --assume-below.

  --assume-below <line>
        The INCLUSIVE FLOOR: "assume this host is below <line>". The version
        anchor is not read and the per-rung version gate is bypassed — every
        rung targeting <line> OR NEWER runs; rungs targeting older lines are
        skipped as genuinely done. Same accepted spellings and the same
        refuse-not-round rule as --installed-version, and mutually exclusive
        with it: the two answer opposite questions about rungs targeting the
        named line, so a command naming both has no one meaning. This flag
        moves only the GATE — receipts still skip finished work unless
        --rerun-recorded is also given.

  --rerun-recorded
        Also run migrations whose receipt says they already completed here, and
        declare the run FORCED to every rung (\$MIGRATION_FORCED=1).
        COSTS: the rung is done again from the top, and a rung that reads
        \$MIGRATION_FORCED may then OVERWRITE state it would otherwise have left
        alone. adopt_user_tree.sh is such a rung: forced, it replaces the
        destination's identity, bridge keys, console pin and config with the
        running user's, after snapshotting both destination roots. That is the
        point of it — a tree adopted from the wrong source cannot be repaired
        any other way — and it is not something to type twice by accident. Read
        the rung you are about to repeat before you use this. It does not force
        past the version gate: name --installed-version as well if the rung is
        one this host's version says it is already past.

  -h, --help
        Print this and exit 0.

This runner starts no service, ever. It stops one only when a rung this
component declares in migrations/component.conf's \$SERVICE_STOP_RUNGS actually
runs — the last line of output says whether that happened, and exit 2 alone does
not mean everything is still up.

Environment seams (the installers set these; see the file header):
  COMP_HOME  COMP_DATA  PREFIX  BIN_DIR  ROOT_HOME  SUDO

Exit codes: 0 nothing applied · 1 refused/failed · 2 ran · 3 ran but a receipt
was lost · 64 the command line was wrong.
EOF
}

# usage_error <what was wrong> — refuse, on stderr, naming BOTH the thing that
# was rejected and what would have been valid. Exit 64 (EX_USAGE): see the exit
# code table in the header for why not 2.
usage_error() {
    warn "$1"
    usage >&2
    exit 64
}

# ---------------------------------------------------------------------------
# valid_version <string> — whether version_lt can actually compare this value.
#
# The gate reads only the first three fields, and version_field maps anything
# non-numeric to 0. That is the right failure for the version FILE (garbage
# resolves to 0.0.0 and every rung applies — fail-safe), and the wrong one for a
# value a human typed: "0.1.x" would resolve to 0.1.0 and quietly select a
# different set of rungs than the operator asked for.
#
# Accepted: an optional leading "v"; MAJOR.MINOR.PATCH all numeric; PATCH may
# carry a -prerelease or +build suffix; anything after a fourth dot is a release
# stamp's .date.sha tail, which the gate ignores and so does this.
# ---------------------------------------------------------------------------
valid_version() {
    _vv="${1##*/}"
    _vv="${_vv#v}"
    case "$_vv" in
    *.*.*) ;;
    *) return 1 ;;
    esac
    _vv_major="${_vv%%.*}"
    _vv_rest="${_vv#*.}"
    _vv_minor="${_vv_rest%%.*}"
    _vv_rest="${_vv_rest#*.}"
    _vv_patch="${_vv_rest%%.*}"
    _vv_patch="${_vv_patch%%-*}"
    _vv_patch="${_vv_patch%%+*}"
    for _vv_field in "$_vv_major" "$_vv_minor" "$_vv_patch"; do
        case "$_vv_field" in
        '' | *[!0-9]*) return 1 ;;
        esac
    done
    return 0
}

# VERSION_NAMED is tracked separately from the value, so that an EMPTY value
# (`--installed-version ""`, or the `--installed-version=` an unexpanded shell
# variable produces) is a refusal rather than silently reading as "not given" —
# an operator who typed the flag and got the file read anyway would have no
# signal at all that their override was dropped. ${VAR:-default} substitutes on
# null as well as unset, so a blanked value cannot be distinguished by the
# value alone; only a second variable can.
NAMED_VERSION=""
VERSION_NAMED=0
FLOOR_VERSION=""
FLOOR_NAMED=0
RERUN_RECORDED=0

while [ $# -gt 0 ]; do
    case "$1" in
    --installed-version)
        [ $# -ge 2 ] || usage_error "--installed-version needs a version, e.g. --installed-version 0.1.115"
        NAMED_VERSION="$2"
        VERSION_NAMED=1
        shift 2
        ;;
    --installed-version=*)
        NAMED_VERSION="${1#--installed-version=}"
        VERSION_NAMED=1
        shift
        ;;
    --assume-below)
        [ $# -ge 2 ] || usage_error "--assume-below needs a version line, e.g. --assume-below 0.2.0"
        FLOOR_VERSION="$2"
        FLOOR_NAMED=1
        shift 2
        ;;
    --assume-below=*)
        FLOOR_VERSION="${1#--assume-below=}"
        FLOOR_NAMED=1
        shift
        ;;
    --rerun-recorded)
        RERUN_RECORDED=1
        shift
        ;;
    -h | --help | help)
        usage
        exit 0
        ;;
    *)
        usage_error "unknown argument '$1'"
        ;;
    esac
done

# Validated HERE — before the tree is even looked at, and far before anything is
# copied or removed. A refusal at this point has touched nothing.
#
# THE TWO VERSION FLAGS ARE MUTUALLY EXCLUSIVE, and that is refused first: they
# answer OPPOSITE questions about a rung targeting the named line
# (--installed-version 0.2.0 says its 0.2.0 rungs are done; --assume-below 0.2.0
# says they are not), so a command naming both has no one meaning for the
# runner to honor — whichever one "won" would silently invert the other.
if [ "$VERSION_NAMED" = 1 ] && [ "$FLOOR_NAMED" = 1 ]; then
    warn "--installed-version and --assume-below were both given, and they disagree"
    warn "by construction about rungs targeting the named line: 'was on <v>' skips"
    warn "rungs targeting exactly <v>, 'assume below <line>' runs them. Name the one"
    warn "that matches what you believe about this host. nothing has been touched."
    exit 64
fi
if [ "$VERSION_NAMED" = 1 ] && ! valid_version "$NAMED_VERSION"; then
    warn "--installed-version '$NAMED_VERSION' is not a version this runner can compare."
    warn "expected MAJOR.MINOR.PATCH, all numeric — e.g. 0.1.115, v0.1.115,"
    warn "0.1.114.2026.08.04.be19c8b6 (a release stamp), or 0.2.10-rc1."
    warn "refusing rather than guessing: an unparseable field reads as 0, so"
    warn "'$NAMED_VERSION' would have selected the rungs for some other version."
    warn "nothing has been touched."
    exit 64
fi
if [ "$FLOOR_NAMED" = 1 ] && ! valid_version "$FLOOR_VERSION"; then
    warn "--assume-below '$FLOOR_VERSION' is not a version this runner can compare."
    warn "expected MAJOR.MINOR.PATCH, all numeric — e.g. 0.2.0, v0.2.0, or a release"
    warn "stamp's 0.2.0.2026.08.17.4e43c2ed."
    warn "refusing rather than guessing: an unparseable field reads as 0, so"
    warn "'$FLOOR_VERSION' would have selected some other line's rungs."
    warn "nothing has been touched."
    exit 64
fi

# ---------------------------------------------------------------------------
# THE LEDGER — migrations/ledger, "<version-this-upgrades-to> <script>" rows,
# oldest first, `#` comments and blank lines ignored.
#
# Append only. Never reorder, never edit a shipped row: the gate is
# "installed < target", so editing a row changes what that rung MEANS for every
# host that has not run it yet.
#
# Read into ONE string and word-split, exactly as the gateway's runner splits
# its here-string, so the two cannot disagree about what a ledger says. Script
# names carry no whitespace, so this is safe, and it avoids a `while read`
# pipeline whose subshell could not accumulate the result.
# ---------------------------------------------------------------------------
if [ ! -f "$LEDGER_FILE" ]; then
    warn "$LEDGER_FILE is missing — THIS RELEASE IS INCOMPLETE."
    warn "the ledger is the list of migrations this component has; without it the"
    warn "runner cannot say whether this host is migrated or merely unexamined."
    warn "refusing rather than reporting a clean no-op. nothing has been touched."
    exit 1
fi
MIGRATIONS="$(sed -e 's/#.*$//' "$LEDGER_FILE")"

# ---------------------------------------------------------------------------
# THE STOP DECLARATION IS CROSS-CHECKED AGAINST THE LEDGER, and a mismatch is
# fatal rather than skippable.
#
# $SERVICE_STOP_RUNGS is the only part of this contract that is a claim rather
# than an observation: the runner cannot see that a rung stops a daemon, it can
# only be told. The failure mode of a claim is a typo, and a typo here is silent
# in the worst possible way — the rung still stops the daemon, the announcement
# never prints, and exit 2 tells the caller everything is still up. So the names
# are required to exist, before any rung runs and before anything is stopped.
# ---------------------------------------------------------------------------
for _ssr in $SERVICE_STOP_RUNGS; do
    _ssr_found=0
    _ssr_want=0
    for _ssr_word in $MIGRATIONS; do
        if [ "$_ssr_want" = 1 ]; then
            _ssr_want=0
            [ "$_ssr_word" = "$_ssr" ] && _ssr_found=1
            continue
        fi
        _ssr_want=1
    done
    if [ "$_ssr_found" != 1 ]; then
        warn "component.conf declares SERVICE_STOP_RUNGS='$SERVICE_STOP_RUNGS', but"
        warn "'$_ssr' is not a script in $LEDGER_FILE."
        warn "THIS RELEASE IS INCOMPLETE — refusing rather than running a ladder whose"
        warn "stop declaration names a rung that does not exist: the rung that DOES stop"
        warn "the daemon would then run unannounced, and exit 2 would tell the caller"
        warn "nothing was left down. Nothing has been touched."
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# installed_version — the recorded version of the component currently
# installed, or empty. The installer writes it as the first line of
# $COMP_HOME/$VERSION_FILE.
# ---------------------------------------------------------------------------
installed_version() {
    if [ ! -f "$COMP_HOME/$VERSION_FILE" ]; then echo ""; return 0; fi
    head -n 1 "$COMP_HOME/$VERSION_FILE" 2>/dev/null | tr -d ' \t\r' || echo ""
}

# ---------------------------------------------------------------------------
# version_field <version> <n> — the nth dot-separated field as a number.
# A missing or non-numeric field reads as 0, which is what makes a garbage
# version resolve to 0.0.0 and so apply every migration (see the header).
# ---------------------------------------------------------------------------
version_field() {
    # A "<component>/" prefix is stripped FIRST, because the value that reaches
    # here is routinely a release TAG (edge/v0.2.0.2026.08.07.4f1c3ec8) and not
    # a bare version. Left in place the first field reads "edge/v0", which is
    # non-numeric and resolves to 0. Today that is invisible, because the major
    # this project ships IS 0 and the accident produces the right answer; at
    # 1.0.0 the same tag would read as 0.0.0 and re-run every rung on a host
    # that is past all of them.
    _f_v="${1##*/}"
    _f_v="${_f_v#v}"
    _f="$(echo "$_f_v" | cut -d. -f"$2" 2>/dev/null || echo 0)"
    # A pre-release or build suffix is not part of the number. 0.2.10-rc1's
    # third field is 10, not "10-rc1" — left unstripped it fails the digit test
    # below and reads as 0, so the whole version reads as 0.2.0, compares OLDER
    # than 0.2.5, and re-runs a migration the host already applied.
    _f="${_f%%-*}"
    _f="${_f%%+*}"
    case "$_f" in
    ''|*[!0-9]*) echo 0 ;;
    *)           echo "$_f" ;;
    esac
}

# ---------------------------------------------------------------------------
# version_lt <a> <b> — true when version a is strictly older than b, comparing
# the first three fields NUMERICALLY. `case` globbing cannot do this: it would
# read 0.10.0 as matching 0.1.* and re-run a migration on a newer host.
# ---------------------------------------------------------------------------
version_lt() {
    _n=1
    while [ "$_n" -le 3 ]; do
        _x="$(version_field "$1" "$_n")"
        _y="$(version_field "$2" "$_n")"
        if [ "$_x" -lt "$_y" ]; then return 0; fi
        if [ "$_x" -gt "$_y" ]; then return 1; fi
        _n=$((_n + 1))
    done
    return 1    # equal is not older
}

# ---------------------------------------------------------------------------
# receipt_state <script> <target> — what this host's receipt for the ledger
# ITEM "<target> <script>" proves, if anything. Echoes one of:
#
#   none              no receipt
#   done              a receipt earned for THIS $COMP_HOME
#   foreign <path>    a receipt earned for a DIFFERENT tree
#   unprovenanced     a receipt that does not say which tree it was earned for
#
# The receipt is written by the RUNNER after the script exits 0, so it means
# "this migration finished", not "this migration started".
#
# THE RECEIPT IS PER ITEM — per ledger ROW, `<script>@<target>.done` — not per
# script file. The ladder's unit of work is the row: one FILE may legitimately
# appear on several rows (re-listed at a newer target when a line gains a step),
# and a receipt keyed by the file alone would let the run that satisfied the
# 0.2.0 row silently satisfy a later 0.3.0 row too — the receipt check runs
# BEFORE the version gate, so the gate would never even see the new item. The
# target in the name is what makes "this file ran once" and "this ITEM ran"
# different facts, which is the whole reason a re-listed row cannot be missed.
#
# LEGACY RECEIPTS (`<script>.done`, written before receipts carried the target)
# are honored ONLY when the ledger names that script exactly once: with one row
# there is exactly one item the old receipt could have witnessed. The moment a
# second row names the same script, a target-less receipt can no longer say
# WHICH item it proves, and it re-evaluates — the fail-safe direction: an
# idempotent rung re-runs, a missed item never hides.
#
# WHY THE TREE IS PART OF THE RECEIPT. Every migration in a ladder is
# TREE-scoped, and which tree that is depends on the scheme and on whose $HOME
# the caller ran under. A receipt with no tree recorded proves something about
# "this host" that was only ever true of one directory on it. That is not
# hypothetical: on the gateway, one installer run under a $HOME whose tree held
# nothing wrote a receipt that then silently skipped the rung for the tree that
# DID hold the host's identity, on every later update, forever.
#
# A receipt that cannot be read even as root, and one whose contents say nothing
# about a tree, both re-evaluate rather than skip — the fail-safe direction, and
# the same one the header picks for a garbage version file. Only "done", a
# receipt that names THIS tree, ends an item's evaluation here.
# ---------------------------------------------------------------------------
# script_row_count <script> — how many ledger rows name <script>. Decides
# whether a legacy target-less receipt is unambiguous (see receipt_state).
script_row_count() {
    _src_n=0
    _src_want=0
    for _src_word in $MIGRATIONS; do
        if [ "$_src_want" = 1 ]; then
            _src_want=0
            [ "$_src_word" = "$1" ] && _src_n=$((_src_n + 1))
            continue
        fi
        _src_want=1
    done
    echo "$_src_n"
}

receipt_state() {
    _rs_file="$RECEIPTS/$1@$2.done"
    # No receipts directory at all: nothing has ever been recorded here, and
    # asking for root to confirm that would put a sudo prompt in front of every
    # host that has never run a migration.
    if [ ! -d "$RECEIPTS" ]; then echo none; return 0; fi
    # The per-item receipt is authoritative when present in any state; the
    # legacy name is consulted only when the item receipt is plainly absent AND
    # the ledger's single row for this script makes the old name unambiguous.
    if [ ! -f "$_rs_file" ] && [ -x "$RECEIPTS" ] \
        && [ -f "$RECEIPTS/$1.done" ] && [ "$(script_row_count "$1")" = 1 ]; then
        _rs_file="$RECEIPTS/$1.done"
    fi
    if [ -r "$_rs_file" ]; then
        _rs_body="$(cat "$_rs_file" 2>/dev/null || true)"
    elif [ -f "$_rs_file" ] || [ ! -x "$RECEIPTS" ]; then
        # Either the receipt is there and unreadable, or the directory cannot be
        # traversed so `-f` cannot answer at all. Both are what a 0700/0600
        # receipt looks like to a caller who is not its owner, and an empty
        # answer here means "could not read", which falls through to none →
        # re-evaluate, the same fail-safe direction an unparseable receipt takes.
        _rs_body="$(as_owner cat "$_rs_file" 2>/dev/null || true)"
        if [ -z "$_rs_body" ]; then echo none; return 0; fi
    else
        echo none
        return 0
    fi
    _rs_home="$(printf '%s\n' "$_rs_body" | sed -n 's/^comp_home=//p' | head -n 1)"
    if [ -z "$_rs_home" ]; then echo unprovenanced; return 0; fi
    if [ "$_rs_home" = "$COMP_HOME" ]; then echo "done"; return 0; fi
    echo "foreign $_rs_home"
}

# ---------------------------------------------------------------------------
# record_migration <script> <target> — write the ITEM's receipt
# (`<script>@<target>.done` — see receipt_state for why the target is part of
# the name). NON-ZERO when it could not, which the caller turns into exit 3.
#
# Failing to record is not cosmetic bookkeeping. The receipt is the gate that
# keeps a migration RE-RUNNABLE; with it absent the only gate left is the
# version anchor, which the caller writes as soon as this runner reports
# success. Reporting plain success after a lost receipt therefore converts a
# migration that would have been retried into one that is version-gated and
# never runs again — the exact silent-loss shape the ladder exists to prevent.
# So the failure travels out as its own exit code instead.
# ---------------------------------------------------------------------------
record_migration() {
    if ! as_owner mkdir -p "$RECEIPTS"; then
        warn "could not create $RECEIPTS — $1 ran but is NOT recorded."
        return 1
    fi
    # 0700 on the directory. The set of receipt files names every rung this host
    # has run (so its version band) and each one names the TREE it was earned
    # for, which is an account's home directory. A traversable receipts
    # directory hands the host's upgrade history and the identity of the
    # migrated user to every local account for free.
    if ! as_owner chmod 0700 "$RECEIPTS" 2>/dev/null; then
        warn "could not chmod 0700 $RECEIPTS — its receipts stay readable to every local user."
    fi
    # Three lines: the script name (first line, for anything reading the
    # shape), the ledger TARGET this item upgrades to, and the TREE this rung
    # was run against. See receipt_state for why the tree and the target are
    # the parts that matter.
    if ! printf '%s\ntarget=%s\ncomp_home=%s\n' "$1" "$2" "$COMP_HOME" | as_owner tee "$RECEIPTS/$1@$2.done" >/dev/null; then
        warn "could not write $RECEIPTS/$1@$2.done — $1 (target $2) ran but is NOT recorded."
        return 1
    fi
    # And 0600 on the file. `tee` creates it under the writer's umask, which on
    # a stock host is 022 → 0644; the directory mode above already closes it,
    # but this is what keeps the receipt closed when that chmod could not be
    # applied or when a later change re-widens the directory for some other
    # file's sake.
    if ! as_owner chmod 0600 "$RECEIPTS/$1@$2.done" 2>/dev/null; then
        warn "could not chmod 0600 $RECEIPTS/$1@$2.done — it stays readable to every local user."
    fi
}

# ---------------------------------------------------------------------------
# receipts_reachable — whether this run could record a rung it ran.
#
# Checked before ANY rung runs, for the same reason the gateway's runner checks
# elevation before it stops anything: discovering it afterwards leaves work done
# and unprovable, and every later run then repeats it. Refusing here costs
# nothing. The probe walks up to the nearest existing ancestor and only READS
# its permissions — it creates nothing, so the "nothing has been touched"
# promise in the refusal stays literally true.
# ---------------------------------------------------------------------------
_receipts_problem=""
receipts_reachable() {
    if receipts_root_writable; then return 0; fi
    if ! elevate true >/dev/null 2>&1; then
        _receipts_problem="$RECEIPTS is not writable by this account and '$SUDO' did not run for us. A '-n' there means the caller found no terminal to prompt on, so root was never asked."
        return 1
    fi
    _rr_probe="$RECEIPTS"
    while [ ! -d "$_rr_probe" ]; do
        _rr_parent="$(dirname "$_rr_probe")"
        [ "$_rr_parent" != "$_rr_probe" ] || break
        _rr_probe="$_rr_parent"
    done
    if ! elevate test -w "$_rr_probe" >/dev/null 2>&1; then
        _receipts_problem="not even root can write $_rr_probe, where $RECEIPTS has to be created."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# run_migration <script> [--applies] — invoke a migration with the env the
# runner RESOLVED, not whatever it inherited.
#
# The probe and the real run go through this one function so the two cannot
# drift: a probe that sees a different environment than the run it authorises is
# answering about a different host. Keeping the block in one place makes that
# invariant structural instead of a comment two callers have to keep honoring.
# ---------------------------------------------------------------------------
run_migration() {
    _rm_script="$1"
    shift
    COMP="$COMP" \
        COMP_HOME="$COMP_HOME" \
        COMP_DATA="$COMP_DATA" \
        BIN_DIR="$BIN_DIR" \
        STALE_USER_BINS="${STALE_USER_BINS:-}" \
        MIGRATION_FORCED="$RERUN_RECORDED" \
        SUDO="$SUDO" \
        LAUNCHCTL="$LAUNCHCTL" \
        SYSTEMCTL="$SYSTEMCTL" \
        sh "$HERE/$_rm_script" "$@"
}

# ---------------------------------------------------------------------------
# Every ladder input lives under $COMP_HOME: the version anchor is read from it,
# and a migration's --applies probe may recognise the host by the shape of the
# tree inside it. With that directory absent there is nothing to evaluate — and
# "no migration applies" and "I could not read the evidence that decides" are
# opposite answers that must not look alike.
#
# THERE IS NO STRANDED-TREE SCAN HERE, and that is a considered difference from
# the gateway's runner rather than an omission. The gateway scans every account
# on the host because ITS tree holds the node's identity and root cannot know
# which account enrolled it — adopting the wrong one re-registers the host. The
# ladders on this runner have no such ambiguity: the `root` scheme's tree is
# root's by construction, and the `user` scheme's is the invoking operator's,
# resolved through $SUDO_USER. A scan would be answering a question neither
# component can ask.
# ---------------------------------------------------------------------------
# AN ABSENT `system` ROOT IS THE PRE-MIGRATION STATE, NOT A MISPLACED TREE.
#
# The skip below asks "is the tree somewhere else?", and for a `user` or `root`
# component that is the right question: the tree's location depends on whose
# $HOME the caller ran under, so an absent one usually means the ladder is aimed
# at the wrong account. A `system` component's roots are fixed by the layout —
# there is no other place they could be — and their absence is exactly the state
# the ladder exists to leave behind. Skipping there would refuse to run the rung
# that CREATES the destination, on precisely the hosts that need it.
if [ ! -d "$COMP_HOME" ] && [ "${COMP_HOME_SCHEME:-user}" = system ]; then
    say "$COMP_HOME does not exist yet — this host has not converged on the"
    say "machine-owned roots. Evaluating every migration anyway: for a system-scheme"
    say "component an absent root is the state to migrate FROM, not a tree in the"
    say "wrong place, and the rung that creates it is on this ladder."
elif [ ! -d "$COMP_HOME" ]; then
    warn "SKIPPING every migration WITHOUT EVALUATING IT: $COMP_HOME does not exist."
    warn "if this host has a $COMP tree somewhere else, name it and re-run:"
    warn "  COMP_HOME=/path/to/.burrowee/$COMP sh $0"
    # An operator who named --installed-version asserted that this host WAS on a
    # given version, and the tree that assertion is about is not here. That is a
    # contradiction, not a no-op: exiting 0 would answer "nothing to do" to a
    # question that was never evaluated, and the operator — mid-incident, on a
    # host whose state is already wrong — would read a clean exit as confirmation
    # that the ladder had been walked.
    if [ "$VERSION_NAMED" = 1 ]; then
        warn "you named --installed-version $NAMED_VERSION, so this is a REFUSAL, not a"
        warn "no-op: the tree that version describes is not at $COMP_HOME."
        exit 1
    fi
    # The same contradiction, spelled with the other flag: --assume-below asserts
    # this host still needs the named line's migrations, and the tree they would
    # migrate is not here to be examined.
    if [ "$FLOOR_NAMED" = 1 ]; then
        warn "you named --assume-below $FLOOR_VERSION, so this is a REFUSAL, not a"
        warn "no-op: the tree those migrations are about is not at $COMP_HOME."
        exit 1
    fi
    exit 0
fi

# SAY WHICH TREE(S) THIS RUN IS ABOUT, before any of them is read.
#
# Every skip, every receipt and every rung below is scoped to these directories,
# and which ones they are depends on the component's scheme and on whose $HOME
# the caller ran under. An operator reading this output otherwise has to know the
# scheme to know what was evaluated — and the failure this whole ladder exists
# for was a daemon reading a tree nobody had looked at.
say "component tree $COMP_HOME"
if [ "$COMP_DATA" != "$COMP_HOME" ]; then
    say "data tree $COMP_DATA"
fi

# The named version REPLACES the file — installed_version() is not called at all
# when one was given, so the ladder is a function of what the operator typed and
# nothing that may be stale on disk. The FLOOR does the same one louder: the
# anchor is not read AND the per-rung comparison inverts — the floor selects
# every rung targeting it or newer, instead of starting above it.
if [ "$FLOOR_NAMED" = 1 ]; then
    _version=""
    say "using --assume-below $FLOOR_VERSION — compared as $(version_field "$FLOOR_VERSION" 1).$(version_field "$FLOOR_VERSION" 2).$(version_field "$FLOOR_VERSION" 3); $COMP_HOME/$VERSION_FILE is NOT read."
    say "every rung targeting that line or newer runs; older targets are treated as done"
elif [ "$VERSION_NAMED" = 1 ]; then
    _version="$NAMED_VERSION"
    say "using --installed-version $_version; $COMP_HOME/$VERSION_FILE is NOT read"
else
    _version="$(installed_version)"
    # SAY WHICH INPUT THE LADDER IS ABOUT TO DECIDE ON. Every skip below is a
    # function of this one value, and "0.2.0 was recorded" and "nothing was
    # recorded, so each rung was asked" lead to opposite reasoning about the
    # same silent exit 0.
    if [ -n "$_version" ]; then
        # The COMPARED triple is printed beside the raw value. What the file
        # holds is a release stamp, what the gate uses is its first three
        # fields, and a reader who cannot see the second has no way to know the
        # date/sha tail was ignored rather than parsed into the comparison.
        say "installed version $_version — compared as $(version_field "$_version" 1).$(version_field "$_version" 2).$(version_field "$_version" 3) (read from $COMP_HOME/$VERSION_FILE)"
    else
        # ABSENT and PRESENT-BUT-EMPTY are different facts and lead to different
        # next questions. "Absent" says nothing is wrong; a zero-byte anchor says
        # a writer got as far as creating the file and wrote no version into it,
        # which is a bug in whatever wrote it.
        if [ -f "$COMP_HOME/$VERSION_FILE" ]; then
            say "no installed version recorded ($COMP_HOME/$VERSION_FILE exists but"
            say "holds no version) — each migration is asked directly whether it applies"
        else
            say "no installed version recorded ($COMP_HOME/$VERSION_FILE is absent) —"
            say "each migration is asked directly whether it applies"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Decide which migrations apply, in ledger order.
# ---------------------------------------------------------------------------
_pending=""
_target=""
_rows=0
for _word in $MIGRATIONS; do
    if [ -z "$_target" ]; then _target="$_word"; continue; fi
    _script="$_word"
    _target_version="$_target"
    _target=""
    _rows=$((_rows + 1))

    # A ledger row whose target is not a version is a DEFECT IN THE LADDER, and
    # it is fatal rather than skippable: version_field maps a non-numeric field
    # to 0, so "latest x.sh" would silently become target 0.0.0 — a row that can
    # never fire, on every host, forever, with no output saying so.
    if ! valid_version "$_target_version"; then
        warn "ledger row '$_target_version $_script' names a target this runner cannot"
        warn "compare. A non-numeric field reads as 0, so this row would silently become"
        warn "target 0.0.0 and never fire on any host. THIS RELEASE IS INCOMPLETE —"
        warn "refusing to run any migration from it, nothing has been touched."
        exit 1
    fi

    # A ledger row whose script is not in the zip means THIS RELEASE IS
    # INCOMPLETE, and that is fatal rather than skippable. Warning and
    # continuing still exits 2, the caller still records the new version, and
    # the numeric gate then closes that rung forever — the host is permanently
    # past a migration it never ran.
    if [ ! -f "$HERE/$_script" ]; then
        warn "$_script is named in the ledger but is not in this release."
        warn "THIS RELEASE IS INCOMPLETE — refusing to run any migration from it,"
        warn "nothing has been touched. Continuing would record a version this host"
        warn "never reached and close the gate on $_script permanently."
        exit 1
    fi

    # The receipt gate is INDEPENDENT of where the ladder starts.
    # --installed-version moves the start; only --rerun-recorded reopens
    # finished work, and it says so out loud every time.
    #
    # A receipt is proof only for the TREE it names, and the three cases are
    # deliberately NOT treated alike:
    #
    #   done            it names this tree — skip, and say so. The ONLY receipt
    #                   state that ends the evaluation.
    #   foreign <path>  it names a DIFFERENT tree. Positive evidence it is not
    #                   about this one, so it settles nothing here.
    #   unprovenanced   it names no tree. It falls through EXACTLY LIKE foreign:
    #                   a receipt that cannot say which tree it witnessed is not
    #                   evidence about this one either.
    _receipt="$(receipt_state "$_script" "$_target_version")"
    case "$_receipt" in
    done)
        if [ "$RERUN_RECORDED" != 1 ]; then
            say "$_script skipped: its receipt records it completed here for $COMP_HOME"
            continue
        fi
        warn "$_script has a receipt saying it already completed here — re-running it"
        warn "because --rerun-recorded was given. Re-read that rung if you have not:"
        warn "an idempotent rung is close to free to repeat, one that rewrites state is not."
        warn "this run is FORCED: a rung that reads \$MIGRATION_FORCED may OVERWRITE state."
        ;;
    unprovenanced)
        say "$_script: it has a receipt, but one that records no tree — so it cannot"
        say "confirm it completed for $COMP_HOME, and a receipt that cannot say is not"
        say "evidence about this tree. Re-evaluating."
        ;;
    "foreign "*)
        say "$_script: its receipt was earned for ${_receipt#foreign }, not"
        say "$COMP_HOME — re-evaluating this tree on its own evidence."
        ;;
    esac

    if [ "$FLOOR_NAMED" = 1 ]; then
        # THE FLOOR GATE, and it is INCLUSIVE: a rung targeting the floor line
        # itself runs — "assume below 0.2.0" means the 0.2.0 work is NOT done.
        # Only a rung targeting a strictly older line is treated as genuinely
        # done. This is the comparison --installed-version cannot express: "was
        # on 0.2.0" skips the 0.2.0 rungs, which is exactly right for a recorded
        # version and exactly wrong for a forcing floor.
        if version_lt "$_target_version" "$FLOOR_VERSION"; then
            say "$_script skipped: its target $_target_version is older than the floor $FLOOR_VERSION"
            continue
        fi
        say "$_script applies: its target $_target_version is at or above the floor $FLOOR_VERSION"
        # Advisory, cannot veto — same contract as a named version: the operator
        # asserted this host's state, and the floor must select the rungs that
        # assertion selects. Disagreement is still said out loud.
        if ! run_migration "$_script" --applies; then
            warn "$_script --applies does NOT recognise this host as one that still needs it,"
            warn "but you named --assume-below $FLOOR_VERSION, which selects it — so it is being run."
            warn "if this host has already moved, expect the rung to do nothing and still leave"
            warn "a receipt saying it ran here. Re-check the floor if that is not what you meant."
        fi
    elif [ -n "$_version" ]; then
        if ! version_lt "$_version" "$_target_version"; then
            say "$_script skipped: installed $_version is not older than $_target_version"
            continue
        fi
        say "$_script applies: installed $_version is older than $_target_version"
        # The probe is advisory here and CANNOT veto (see the header): a named
        # version must select the same rungs a recorded one would. But "the
        # version says yes and the structure says no" is real information — it
        # usually means the host has already moved — and the operator who typed
        # the version is the one who can act on it, so it is never swallowed.
        if [ "$VERSION_NAMED" = 1 ] && ! run_migration "$_script" --applies; then
            warn "$_script --applies does NOT recognise this host as one that still needs it,"
            warn "but you named $_version, which is older than $_target_version — so it is being run."
            warn "if this host has already moved, expect the rung to do nothing and still leave"
            warn "a receipt saying it ran here. Re-check the version if that is not what you meant."
        fi
    else
        if ! run_migration "$_script" --applies; then
            say "$_script skipped: no recorded version, and --applies does not recognise"
            say "$COMP_HOME as a host that still needs it"
            continue
        fi
        say "$_script applies: no recorded version, and it recognises this host"
    fi
    # Pending entries carry the ITEM — `<script>@<target>` — not the bare file:
    # the receipt written after the run is per item (see receipt_state), and one
    # file re-listed at two targets is two pending items, run and receipted
    # separately.
    _pending="${_pending:+$_pending }$_script@$_target_version"
done

# A ledger that word-splits into an odd number of words has a row with a target
# and no script, or a script and no target. Detected AFTER the walk because the
# dangling word is only visible once the pairs are consumed — and it is fatal for
# the same reason a missing script is: the runner cannot say what the ladder
# contains, so it must not report on what this host has reached.
if [ -n "$_target" ]; then
    warn "$LEDGER_FILE ends with a dangling word '$_target' — its rows are not"
    warn "(version, script) pairs. THIS RELEASE IS INCOMPLETE; refusing rather than"
    warn "running a ladder this runner cannot read. Nothing has been touched."
    exit 1
fi
if [ "$_rows" = 0 ]; then
    warn "$LEDGER_FILE holds no migration rows. THIS RELEASE IS INCOMPLETE: a ladder"
    warn "with no rungs and a ladder whose rungs went missing are the same silent"
    warn "exit 0, and only one of them is correct. Nothing has been touched."
    exit 1
fi

# NOTHING APPLIED IS A CONCLUSION, AND IT IS SAID OUT LOUD. Each rung above has
# already said why it declined; this line closes the ladder.
if [ -z "$_pending" ]; then
    say "nothing applied — no migration in the ledger is pending on this host"
    exit 0
fi

# ---------------------------------------------------------------------------
# Run them.
# ---------------------------------------------------------------------------
if ! receipts_reachable; then
    warn "cannot record a migration on this host — refusing to start, nothing has"
    warn "been touched."
    warn "$_receipts_problem"
    warn "a rung that runs and cannot be recorded runs again on every later install;"
    warn "refusing now costs nothing. Re-run as the account that owns $COMP_HOME."
    exit 1
fi

say "pending: $_pending"

# SAY IT BEFORE IT HAPPENS. An operator reading this mid-incident needs to know
# the daemon is about to go down while they can still decide not to, and after
# the fact is not that moment. This is the whole reason the stop is DECLARED in
# component.conf rather than merely observed afterwards.
_stopped=""
for _item in $_pending; do
    _p_script="${_item%@*}"
    if stops_the_service "$_p_script"; then
        say "$_p_script will STOP burrowee-$COMP before it copies, and this runner never"
        say "starts anything — the caller does. See that rung's header for why the"
        say "destination has to hold still."
    fi
done

_unrecorded=""
for _item in $_pending; do
    _p_script="${_item%@*}"
    _p_target="${_item##*@}"
    say "running $_p_script (target $_p_target)"
    if ! run_migration "$_p_script"; then
        warn "$_p_script FAILED. fix the cause above and re-run the installer;"
        warn "completed migrations are recorded and will not be repeated."
        if stops_the_service "$_p_script"; then
            warn "$_p_script is declared to stop burrowee-$COMP: it may have stopped the"
            warn "daemon before it failed. Check, and start it if it is down."
        fi
        exit 1
    fi
    if stops_the_service "$_p_script"; then
        _stopped="${_stopped:+$_stopped }$_p_script"
    fi
    # A lost receipt does not stop the remaining rungs: the cheapest safe end
    # state is still "walk to the top, then report". The failure is carried to
    # the exit code instead.
    if ! record_migration "$_p_script" "$_p_target"; then
        _unrecorded="${_unrecorded:+$_unrecorded }$_item"
    fi
    say "$_p_script complete"
done

if [ -n "$_unrecorded" ]; then
    warn "migrations RAN but were NOT recorded: $_unrecorded"
    warn "the caller must NOT record the new version. Without the receipt the numeric"
    warn "gate is the only gate left, and recording the version closes it forever on a"
    warn "rung whose completion nothing on this host can prove."
    warn "fix the cause above and re-run: every migration is idempotent."
    if [ -n "$_stopped" ]; then
        warn "burrowee-$COMP is also STOPPED (by $_stopped) — start it. A lost receipt"
        warn "does not bring a daemon back up."
    fi
    exit 3
fi

# THE LAST LINE IS ALWAYS ABOUT THE SERVICE, and it is two different sentences
# rather than one hedged one. "A rung may have stopped it" is not something a
# caller can act on; "it is stopped" and "nothing was stopped" are.
if [ -n "$_stopped" ]; then
    say "migrations complete — burrowee-$COMP is STOPPED (by $_stopped) and the caller"
    say "must start it. This runner starts nothing."
else
    say "migrations complete — no service was stopped, so there is nothing to start."
fi
exit 2
