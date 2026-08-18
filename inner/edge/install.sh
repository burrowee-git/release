#!/bin/sh
# Burrowee inner installer — edge (POSIX sh, macOS + Linux).
#
# Ships at the ROOT of the verified release zip as `install.sh`. The outer
# bootstrap verifies the zip (minisign + sha256) and ONLY THEN execs this with
# cwd = the unzipped dir, so the binaries sit alongside this script.
#
# ROOT-ONLY, ONE DESTINATION. The binaries go to $BIN_DIR — /usr/local/bin,
# root-owned, ALWAYS — and the run sets up a MANAGED ROOT SERVICE: a systemd
# system unit on Linux, a launchd LaunchDaemon on macOS, running
# `burrowee-edge run`, enabled and (re)started. The service's config home is
# root's home + /.burrowee/edge — /root on Linux, /var/root on macOS (NOT /root,
# which sits on the sealed system volume) — and HOME is set to it in the
# unit/plist so the daemon resolves the same dir. The documented entry point is
# therefore `curl ... | sudo sh`, which is what the console mints.
#
# THE PER-USER FLOW IS GONE, not de-defaulted. A set PREFIX is REFUSED, loudly,
# and so is a run that never reached uid 0 — both before anything is placed,
# never silently redirected. This mirrors the gateway's 0.2.0 collapse
# (inner/gateway/install.sh, whose header carries the full reasoning) and exists
# for the same failure: a per-user install is invisible to every root-scheme
# consumer. The dispatcher resolves gateway/edge/register at the ABSOLUTE
# /usr/local/bin, and a root daemon's unit pins
# PATH=/usr/bin:/bin:/usr/sbin:/sbin, so a PATH lookup from one can reach
# nothing under $HOME. Observed on a production node, 2026-08-13: a consumer's
# root daemon crash-looped 50 times unable to find a component that had
# "successfully installed" into /home/ubuntu/.local/bin. A component that
# installs where its consumers cannot look has not installed, however cleanly it
# exits.
#
# Removing the flow does not remove what it left behind, and the leftovers keep
# winning: $HOME/.local/bin PRECEDES /usr/local/bin on a normal PATH. So an
# install also sweeps the stale per-user copies of its own binaries, by exact
# name, after the units naming $BIN_DIR are loaded — sweep_stale_user_bins,
# which loads the shared migrations/lib_stale_user_bins.sh rather than
# open-coding a second copy of it. What it does NOT sweep is the per-user
# CONFIG tree an earlier unprivileged install paired: that holds this edge's
# identity, so it is reported, never touched — note_orphaned_user_state.
#
# THIS RELEASE ALSO CARRIES A MIGRATION LADDER (migrations/), and the sweep is
# a rung on it as well as a step here. install.sh runs only when somebody runs
# the installer and the updater never does, so a host updated in place kept its
# stale per-user copies indefinitely; the rung is what reaches those hosts. The
# ladder is walked unconditionally by run_migration_ladder and its exit code is
# acted on: 1 stops the install before any unit is written, 3 completes the
# install but withholds the version anchor.
#
# The system [Service] block mirrors the relay system unit (Restart / RestartSec
# / TimeoutStopSec / HOME); ExecStart is `<bin> run` (the edge daemon verb).
#
# Idempotent: re-running replaces the binaries + unit and restarts the service,
# so the same one-liner serves both fresh installs and in-place updates.
#
# Set BURROWEE_UNITS_ONLY=1 to re-render + reload the managed service units
# without touching binaries or the network — the offline reinstall entrypoint
# run by the component's LocalReinstall.
set -eu

BINS="burrowee burrowee-edge burrowee-edge-cli burrowee-edge-updater"
COMP=edge

# A SET PREFIX IS REFUSED, not honoured and not silently overridden, and it is
# refused HERE — before a directory is created, a binary placed or a unit
# written. Refusing is the point: an operator who typed PREFIX=$HOME/.local and
# got a root-owned /usr/local/bin would be handed exactly the class of surprise
# this collapse exists to remove, one direction reversed. They get told instead,
# and the process that set it (a shell profile, an outer bootstrap, a wrapper)
# is the thing that has to change. The version is named because the operator
# hitting this needs to know since when; it is asserted by the suite
# (install_test/root_only_test.go), so it cannot drift away from the release it
# describes without a test failing.
if [ -n "${PREFIX:-}" ]; then
    echo "install: PREFIX is set to '$PREFIX', but as of edge 0.2.0 this installer" >&2
    echo "install: has one destination: /usr/local/bin, root-owned. The per-user prefix" >&2
    echo "install: flow is gone — edge's service units run as root and name the binaries" >&2
    echo "install: absolutely, and other components resolve /usr/local/bin/burrowee by" >&2
    echo "install: absolute path, so a per-user copy is invisible to both." >&2
    echo "hint: unset PREFIX and re-run; nothing has been installed." >&2
    exit 1
fi

# ── system install paths ─────────────────────────────────────────────────────
# SYS_BIN_DIR + SYSTEMD_UNIT_DIR + LAUNCHD_PLIST_DIR default to the real system
# locations; they are overridable only so the Go install-test harness can
# exercise this script in a sandbox without actually being root — never set them
# on a real host. SYS_BIN_DIR is this component's equivalent of the gateway's
# BURROWEE_BIN_DIR seam; it keeps its name because the rendered units, and every
# caller that already sets it, are written in terms of it.
SYS_BIN_DIR="${SYS_BIN_DIR:-/usr/local/bin}"
# BIN_DIR and SYS_BIN_DIR are ONE destination under two names: the units and the
# test harness spell it SYS_BIN_DIR, the placement/uninstall code below spells it
# BIN_DIR, and since the 0.2.0 collapse they can never differ. Resolved HERE, at
# the top, rather than beside the config home further down — the shared sweep
# library reads $BIN_DIR for the guard that refuses to sweep the install
# destination, and a library sourced before the value was decided would have
# taken the production default while this run installed somewhere else.
BIN_DIR="$SYS_BIN_DIR"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
SYSTEMD_UNIT="$SYSTEMD_UNIT_DIR/burrowee-edge.service"
SYSTEMD_UPDATER_UNIT="$SYSTEMD_UNIT_DIR/burrowee-edge-updater.service"
LAUNCHD_PLIST_DIR="${LAUNCHD_PLIST_DIR:-/Library/LaunchDaemons}"
LAUNCHD_PLIST="$LAUNCHD_PLIST_DIR/com.burrowee.edge.plist"
LAUNCHD_LABEL="com.burrowee.edge"
LAUNCHD_UPDATER_PLIST="$LAUNCHD_PLIST_DIR/com.burrowee.edge.updater.plist"
LAUNCHD_UPDATER_LABEL="com.burrowee.edge.updater"
# Legacy pre-rename system labels/plists earlier installers wrote — migrated
# away on install, removed on uninstall.
LEGACY_LAUNCHD_LABEL="org.burrowee.edge"
LEGACY_LAUNCHD_UPDATER_LABEL="org.burrowee.edge.updater"

# remove_legacy_launchd_units — boot out + delete the org.burrowee.* system
# LaunchDaemons a pre-rename root install wrote. Best-effort; root-only caller.
remove_legacy_launchd_units() {
    launchctl bootout "system/$LEGACY_LAUNCHD_LABEL" 2>/dev/null || true
    launchctl bootout "system/$LEGACY_LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
    rm -f "$LAUNCHD_PLIST_DIR/$LEGACY_LAUNCHD_LABEL.plist" \
          "$LAUNCHD_PLIST_DIR/$LEGACY_LAUNCHD_UPDATER_LABEL.plist"
}

is_root() { [ "$(id -u)" = 0 ]; }

# ---------------------------------------------------------------------------
# THE STALE PER-USER BINARY SWEEP, AND THE MIGRATION LADDER IT NOW ALSO RIDES ON
#
# Until the 0.2.0 collapse the unprivileged branch dropped the binaries in
# $HOME/.local/bin, and before the managed root service existed that was the
# only shape an edge install took. A host converging onto the root scheme gets
# everything in /usr/local/bin and keeps the old copies — and $HOME/.local/bin
# PRECEDES /usr/local/bin on a normal PATH, so every unqualified `burrowee` or
# `burrowee-edge-cli` an operator types resolves to the OLD binary while the
# system unit runs the new one.
#
# THE SWEEP IS NOT OPEN-CODED HERE ANY MORE. It lives in
# migrations/lib_stale_user_bins.sh, inside this same bundle, and the 0.2.0
# ladder rung (migrations/stale_user_bins.sh) sources the same file out of the
# same directory. Every guard in it fails silently in the safe-looking direction
# — a sweep pointed at the wrong home finds nothing and reports success; an
# ownership check that admits too much deletes an operator's own file and
# reports success too — so a second copy that drifted would look exactly like
# the original right up to the deletion it got wrong.
#
# IT IS ALSO A LADDER RUNG NOW, and that is why the drift was worth fixing.
# install.sh runs only when somebody runs the installer, and THE UPDATER NEVER
# DOES: it runs update.sh, swaps binaries and restarts the daemon. So a host
# updated in place kept its stale per-user copies forever. Making the sweep a
# rung is what reaches those hosts; keeping the call HERE as well is deliberate
# rather than redundant, because a FRESH install must not depend on the ladder
# being coherent, and the sweep is idempotent.
#
# THE ORDERING IS A SAFETY PROPERTY, not a tidiness preference. A host arriving
# here may still be running a unit whose ExecStart names the per-user path; the
# macOS LaunchDaemons this script writes gate KeepAlive on PathState, so
# unlinking the binary does not stale a future restart — it stops the running
# daemon. So the sweep runs only after the new binaries are in $SYS_BIN_DIR and
# the units naming them have been rendered and (re)loaded, and even then it
# refuses outright when a unit file on this host still names the old directory.
#
# THE BINARIES ARE ALL IT TOUCHES. The per-user CONFIG tree beside them
# (~/.burrowee/edge: this edge's identity, console.json, covers) is this host's
# pairing, and the root daemon reads a different one — so it is REPORTED and
# left exactly where it is (note_orphaned_user_state). Deleting it would throw
# away the only copy of an identity; moving it would silently re-point a paired
# edge, from an installer, with no operator in the loop.
# ---------------------------------------------------------------------------

# The library spells the unit directories LAUNCHD_DIR / SYSTEMD_DIR — the same
# names the gateway's installer and the gateway repo's runner use. This script
# (and every caller that already sets them, including the Go install-test
# harness) spells them LAUNCHD_PLIST_DIR / SYSTEMD_UNIT_DIR. Mapped here, once,
# so a sandboxed run cannot leak into the real /Library/LaunchDaemons.
LAUNCHD_DIR="$LAUNCHD_PLIST_DIR"
SYSTEMD_DIR="$SYSTEMD_UNIT_DIR"

# MIGRATIONS_DIR — the ladder shipped beside this installer, or empty when this
# bundle carries none. A bundle with no migrations/ is an OLD bundle, not a
# broken one (a $COMP_HOME self-copy from an install that predates the
# directory, reachable only through BURROWEE_UNITS_ONLY), so it stays quiet —
# while a bundle that HAS migrations/ and is missing a file inside it is a
# mis-assembled release, which this project has shipped once and must never
# ship quietly again.
MIGRATIONS_DIR=""
if [ -d "$(dirname "$0")/migrations" ]; then
    MIGRATIONS_DIR="$(dirname "$0")/migrations"
fi

# SWEEP_LIB_LOADED gates both call sites below. It is a separate variable and
# not a test of $MIGRATIONS_DIR, because "the directory is there" and "the
# functions are defined" are different facts and the second is the one the
# callers depend on.
SWEEP_LIB_LOADED=0
if [ -n "$MIGRATIONS_DIR" ]; then
    if [ -f "$MIGRATIONS_DIR/lib_stale_user_bins.sh" ] && [ -f "$MIGRATIONS_DIR/lib_paths.sh" ]; then
        # LIB_STALE_USER_BINS_DIR pins where the library looks for its siblings
        # (lib_paths.sh, component.conf). Without it the library resolves them
        # from $0 — which, sourced from here, is the BUNDLE ROOT and not
        # migrations/, so component.conf would never be found and the sweep
        # would silently have no names to sweep.
        LIB_STALE_USER_BINS_DIR="$MIGRATIONS_DIR"
        export LIB_STALE_USER_BINS_DIR
        # shellcheck source=/dev/null
        . "$MIGRATIONS_DIR/lib_paths.sh"
        # shellcheck source=/dev/null
        . "$MIGRATIONS_DIR/lib_stale_user_bins.sh"
        SWEEP_LIB_LOADED=1
        # THE TWO LISTS MUST AGREE. $BINS is what this installer PLACES;
        # $STALE_USER_BINS (from migrations/component.conf) is what the sweep
        # removes, and it is the one the ladder rung uses too. A name added to
        # one and not the other is a binary that is installed and never swept —
        # a shadowing copy left on PATH, which is this whole defect — or one
        # swept and never installed. Neither is visible without saying so out
        # loud, because the sweep's normal output on a converged host is nothing
        # at all.
        if [ "$BINS" != "$STALE_USER_BINS" ]; then
            echo "note: this installer places [$BINS]" >&2
            echo "note: but $MIGRATIONS_DIR/component.conf sweeps [$STALE_USER_BINS]." >&2
            echo "note: the two lists disagree, so some name is installed and never swept" >&2
            echo "note: (it keeps shadowing $BIN_DIR on PATH) or swept and never installed." >&2
        fi
    else
        echo "note: $MIGRATIONS_DIR carries no lib_stale_user_bins.sh + lib_paths.sh pair —" >&2
        echo "note: THIS RELEASE IS INCOMPLETE. The pre-0.2.0 per-user copies of these" >&2
        echo "note: binaries are NOT being swept, and they precede $BIN_DIR on a normal" >&2
        echo "note: PATH. Remove them by hand, or re-run a complete release." >&2
    fi
fi

# sweep_stale_user_bins — run the library's sweep, or say why it cannot.
# Named differently from the library's own remove_stale_user_bins on purpose:
# two definitions of one name in one shell, with which one a call reaches
# depending on whether the source has happened yet, is not a hazard worth
# creating to save a word.
sweep_stale_user_bins() {
    [ "$SWEEP_LIB_LOADED" = 1 ] || return 0
    remove_stale_user_bins
}

# ---------------------------------------------------------------------------
# run_migration_ladder — walk migrations/run.sh, which runs every migration in
# migrations/ledger this host has not reached yet, oldest first.
#
# The runner owns the whole decision: it reads the version anchor, gates each
# rung on `installed < target`, runs them oldest first, and records each one
# that completes. It is a no-op unless one applies, so this is called
# UNCONDITIONALLY — a caller that decided for itself when the ladder was worth
# running would be a second copy of the gate.
#
# WHERE IT SITS IN THE FLOW, and why. It runs after the binaries are in
# $BIN_DIR and before the version marker is written:
#
#   * AFTER the binaries, because the 0.2.0 rung removes the per-user copies
#     that SHADOW $BIN_DIR on PATH. Removing them before the replacements exist
#     would leave an operator's `burrowee-edge-cli` resolving to nothing at all
#     for the length of an install.
#   * BEFORE the version marker, because exit 3 means "the rung ran and its
#     receipt was lost", and the only correct response to that is to withhold
#     the anchor so the next install re-runs the rung. An anchor written before
#     the ladder ran could not be withheld after it.
#
# EXIT CODES — the runner's contract, acted on rather than merely observed:
#   0  nothing applied. Continue.
#   2  migrations ran. Continue. (This runner stops no service — see its header.)
#   3  ran, but a receipt was lost: continue, and DO NOT record the version.
#   1 or anything else  FATAL. Stopping here leaves the binaries placed and no
#      units written, which is loud and re-runnable; carrying on would write
#      units and an anchor for a migration that refused, and the anchor is what
#      closes the gate on that rung permanently.
#
# Not found is not an error: BURROWEE_UNITS_ONLY can run from $COMP_HOME's
# self-copy, and an install predating migrations/ has none beside it.
# ---------------------------------------------------------------------------
MIGRATE_UNRECORDED=0
run_migration_ladder() {
    [ -n "$MIGRATIONS_DIR" ] || return 0
    [ -f "$MIGRATIONS_DIR/run.sh" ] || return 0
    # $COMP_HOME must exist before the runner is asked about it: an absent tree
    # is the runner's "I could not read the evidence" answer, and on a host
    # converging off the per-user layout root's tree legitimately does not exist
    # yet. Creating it here makes the ladder's input a fact rather than an
    # accident of which step happened to mkdir first.
    mkdir -p "$COMP_HOME" 2>/dev/null || true
    set +e
    COMP_HOME="$COMP_HOME" \
        BIN_DIR="$BIN_DIR" \
        LAUNCHD_DIR="$LAUNCHD_PLIST_DIR" \
        SYSTEMD_DIR="$SYSTEMD_UNIT_DIR" \
        sh "$MIGRATIONS_DIR/run.sh"
    _rml_rc=$?
    set -e
    case "$_rml_rc" in
    0 | 2) ;;
    3) MIGRATE_UNRECORDED=1 ;;
    *)
        echo "error: a state migration refused or failed — stopping before the service" >&2
        echo "error: units are written. The binaries are in $BIN_DIR; nothing else on this" >&2
        echo "error: host has been changed." >&2
        echo "hint: fix the cause reported above and re-run this installer." >&2
        exit 1
        ;;
    esac
}

# report_unrecorded_migration — say that a migration completed without its
# receipt, and that the version anchor was withheld on purpose so it runs again.
report_unrecorded_migration() {
    [ "$MIGRATE_UNRECORDED" = 1 ] || return 0
    echo "note: a migration completed but its receipt could not be written." >&2
    echo "note: the installed version is deliberately NOT recorded, so the next install" >&2
    echo "note: re-runs the migration (they are idempotent) rather than gating it off" >&2
    echo "note: on a version number with no receipt behind it." >&2
}

# note_orphaned_user_state — REPORT, and never touch, the per-user config tree an
# earlier unprivileged install paired.
#
# The managed daemon reads $COMP_HOME under ROOT's home. A pre-collapse install's
# identity sits under the OPERATOR's ~/.burrowee/edge and does not travel with
# the binaries, so a host converging onto the root scheme comes up as a healthy,
# running, UNPAIRED edge. Silence is the worst outcome available here: the
# install exits 0, the service is up, and nothing gives the operator a reason to
# look for the identity that already exists a directory away.
#
# Says nothing when there is no per-user state. That the ROOT tree is unpaired is
# the CALLER's condition — this is only reached from the "next: pair this edge"
# branch — and it is not re-tested here: a second copy of a condition its only
# call site already decided cannot fail independently, it can only drift.
#
# It resolves the operator's home through the SAME operator_home the sweep uses
# — one definition, in migrations/lib_paths.sh — so the directory it reports on
# and the directory the sweep acted on can never be two different answers. With
# no library loaded it says nothing rather than guessing $HOME, which under
# `sudo sh` is root's and holds no per-user tree: a report naming the wrong
# directory is worse than no report, because it is acted on.
note_orphaned_user_state() {
    [ "$SWEEP_LIB_LOADED" = 1 ] || return 0
    _nos_home="$(operator_home)"
    [ -n "$_nos_home" ] || return 0
    _nos_dir="$_nos_home/.burrowee/$COMP"
    if [ "$_nos_dir" = "$COMP_HOME" ]; then return 0; fi
    if [ ! -d "$_nos_dir/identity" ] && [ ! -f "$_nos_dir/console.json" ]; then return 0; fi
    echo "note: $_nos_dir holds a paired edge identity from an earlier per-user install," >&2
    echo "note: but the managed service reads $COMP_HOME — this edge starts UNPAIRED." >&2
    echo "hint: pair it again (burrowee $COMP cli bootstrap <blob> <pin>), or stop the" >&2
    echo "hint: service and move that state across by hand. Nothing was removed." >&2
}

# ── the one install target ───────────────────────────────────────────────────
# The service's config home. $BIN_DIR was decided at the top of this file,
# beside $SYS_BIN_DIR — there is no branch left to take, so every step below
# that only made sense for a root install (setup_root_service, the unit teardown
# on uninstall, the stale-bin sweep, the version marker under root's home) now
# runs on EVERY install.
#
# The config home is root's home + /.burrowee/edge, because the daemon that reads
# it runs as root. Root's home is /root on Linux but /var/root on macOS — /root
# sits on the sealed read-only system volume there, so any mkdir under it fails.
# ROOT_HOME is overridable only for the Go install-test harness (like
# SYS_BIN_DIR). It is resolved from ~root rather than from $HOME because under
# `sudo sh` $HOME is not reliably root's — macOS sudo keeps the invoking user's
# by default.
#
# root_home() from migrations/lib_paths.sh is the ONE implementation of that
# rule, shared with the migration runner, so the tree this installer writes and
# the tree the ladder migrates cannot be two different directories. The inline
# fallback below is reached only by a bundle that carries no migrations/ at all
# — a $COMP_HOME self-copy predating the directory, which only
# BURROWEE_UNITS_ONLY runs — and it is deliberately the same rule rather than a
# simplification of it.
if command -v root_home >/dev/null 2>&1; then
    ROOT_HOME="$(root_home)"
elif [ "$(uname -s)" = "Darwin" ]; then
    ROOT_HOME="${ROOT_HOME:-$(eval echo ~root)}"
    case "$ROOT_HOME" in /*) ;; *) ROOT_HOME=/var/root ;; esac
else
    ROOT_HOME="${ROOT_HOME:-/root}"
fi
COMP_HOME="$ROOT_HOME/.burrowee/$COMP"
VERSION_MARKER="$COMP_HOME/installed-version"

# ver_lt A B — true (exit 0) when version A < B, comparing the vMAJOR.MINOR.PATCH
# prefix numerically (any .date.sha suffix is ignored). Empty A sorts as 0.0.0.
ver_lt() {
    _a="${1#v}"; _b="${2#v}"
    _a1=$(printf '%s' "$_a" | cut -d. -f1); _a1=$(printf '%s' "${_a1:-0}" | tr -cd 0-9); _a1=${_a1:-0}
    _a2=$(printf '%s' "$_a" | cut -d. -f2); _a2=$(printf '%s' "${_a2:-0}" | tr -cd 0-9); _a2=${_a2:-0}
    _a3=$(printf '%s' "$_a" | cut -d. -f3); _a3=$(printf '%s' "${_a3:-0}" | tr -cd 0-9); _a3=${_a3:-0}
    _b1=$(printf '%s' "$_b" | cut -d. -f1); _b1=$(printf '%s' "${_b1:-0}" | tr -cd 0-9); _b1=${_b1:-0}
    _b2=$(printf '%s' "$_b" | cut -d. -f2); _b2=$(printf '%s' "${_b2:-0}" | tr -cd 0-9); _b2=${_b2:-0}
    _b3=$(printf '%s' "$_b" | cut -d. -f3); _b3=$(printf '%s' "${_b3:-0}" | tr -cd 0-9); _b3=${_b3:-0}
    [ "$_a1" -lt "$_b1" ] && return 0; [ "$_a1" -gt "$_b1" ] && return 1
    [ "$_a2" -lt "$_b2" ] && return 0; [ "$_a2" -gt "$_b2" ] && return 1
    [ "$_a3" -lt "$_b3" ] && return 0
    return 1
}

# seed_if_absent KEY VAL — set the config key only when unset (never clobber an
# operator value). burrowee-edge-cli `config get` exits non-zero when absent.
seed_if_absent() {
    if "$BIN_DIR/burrowee-edge-cli" config get "$1" >/dev/null 2>&1; then
        return 0
    fi
    "$BIN_DIR/burrowee-edge-cli" config set "$1" "$2" >/dev/null 2>&1 \
        || echo "warning: could not seed default $1=$2" >&2
}

# migrate_config OLD — apply version-gated default seeds. Each block runs
# only when crossing into the version that introduced its default.
migrate_config() {
    _old="$1"
    # introduced v0.1.32 — high-throughput smux buffers (the buffer-profile feature):
    if ver_lt "$_old" "v0.1.32"; then
        seed_if_absent buffer_stream  32m
        seed_if_absent buffer_session 256m
    fi
}

# setup_root_service — render BOTH managed SYSTEM service units for the host init
# system and (re)load the serve unit (the updater unit is rendered but left
# opt-in). Root-only caller. Renders unit FILES pointing at $SYS_BIN_DIR; it
# never places binaries, so it is safe to call from the units-only reinstall
# path as well as fresh install / update.
setup_root_service() {
    if [ "$(uname -s)" = "Darwin" ]; then
        # ── macOS: root LaunchDaemon ──────────────────────────────────────────
        # HOME=$ROOT_HOME (/var/root) so the daemon's os.UserHomeDir() resolves
        # $ROOT_HOME/.burrowee/edge — launchd daemons get no HOME by default
        # (mirrors the systemd unit's Environment=HOME=/root).
        # KeepAlive.PathState (matching core/setup's system units, which land on
        # the SAME paths): the update-restart rung SIGTERMs the running daemon
        # and relies on the supervisor respawning it after a CLEAN exit —
        # SuccessfulExit=false would leave a cleanly-exited daemon down.
        cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key><array><string>$SYS_BIN_DIR/burrowee-edge</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$SYS_BIN_DIR/burrowee-edge</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict><key>HOME</key><string>$ROOT_HOME</string></dict>
</dict></plist>
EOF
        chmod 0644 "$LAUNCHD_PLIST"
        echo "wrote LaunchDaemon → $LAUNCHD_PLIST"

        # Updater LaunchDaemon (mirrors the disabled systemd updater unit; HOME
        # so its console.json + identity resolve under $ROOT_HOME/.burrowee/edge).
        # Rendered but NOT bootstrapped — the auto-updater is owner opt-in.
        cat > "$LAUNCHD_UPDATER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCHD_UPDATER_LABEL</string>
  <key>ProgramArguments</key><array><string>$SYS_BIN_DIR/burrowee-edge-updater</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$SYS_BIN_DIR/burrowee-edge-updater</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict><key>HOME</key><string>$ROOT_HOME</string></dict>
</dict></plist>
EOF
        chmod 0644 "$LAUNCHD_UPDATER_PLIST"
        echo "wrote LaunchDaemon → $LAUNCHD_UPDATER_PLIST (not bootstrapped — enable with: launchctl bootstrap system $LAUNCHD_UPDATER_PLIST)"

        # Migrate away the pre-rename org.burrowee.* units before loading the
        # com.burrowee.* ones — two labels must never run the same daemon.
        remove_legacy_launchd_units

        launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null || true
        launchctl bootstrap system "$LAUNCHD_PLIST"
        launchctl enable "system/$LAUNCHD_LABEL"
        launchctl kickstart -k "system/$LAUNCHD_LABEL" 2>/dev/null || true
        echo "launchd service $LAUNCHD_LABEL enabled + started"

        # If the owner opted the auto-updater in (its LaunchDaemon is already
        # loaded), a reinstall must advance THAT daemon too — otherwise a stale
        # updater keeps running old code and future pushes deadlock. Restart it
        # ONLY when already loaded; never bootstrap a not-loaded updater here (it
        # stays owner opt-in). The updater's own push path runs update.sh, not this
        # installer, so this can never self-kill.
        if launchctl print "system/$LAUNCHD_UPDATER_LABEL" >/dev/null 2>&1; then
            launchctl kickstart -k "system/$LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
            echo "restarted $LAUNCHD_UPDATER_LABEL (opted in) to pick up new binary"
        fi
    else
        # ── Linux: systemd system unit ([Service] mirrors the relay unit) ─────
        # HOME=/root so the daemon's os.UserHomeDir() resolves /root/.burrowee/edge
        # (a root system service has no HOME otherwise).
        # Restart=always (matching core/setup's system units, which land on the
        # SAME paths): the update-restart rung SIGTERMs the running daemon and
        # relies on systemd respawning it after a CLEAN exit — on-failure would
        # leave a cleanly-exited daemon down.
        mkdir -p "$(dirname "$SYSTEMD_UNIT")"
        cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=burrowee edge (self-hosted relay-edge)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
ExecStart=$SYS_BIN_DIR/burrowee-edge run
Restart=always
RestartSec=2
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
        chmod 0644 "$SYSTEMD_UNIT"
        echo "wrote systemd unit → $SYSTEMD_UNIT"

        # Updater system unit ([Service] mirrors the serve unit; HOME=/root so its
        # console.json + identity resolve to /root/.burrowee/edge). Rendered but
        # left DISABLED — the auto-updater is owner opt-in (enable + start it with
        # `systemctl enable --now burrowee-edge-updater`).
        cat > "$SYSTEMD_UPDATER_UNIT" <<EOF
[Unit]
Description=burrowee edge updater
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
ExecStart=$SYS_BIN_DIR/burrowee-edge-updater run
Restart=always
RestartSec=2
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
        chmod 0644 "$SYSTEMD_UPDATER_UNIT"
        echo "wrote systemd unit → $SYSTEMD_UPDATER_UNIT (disabled — enable with: systemctl enable --now burrowee-edge-updater)"

        systemctl daemon-reload
        systemctl enable --now burrowee-edge
        systemctl restart burrowee-edge
        echo "systemd service burrowee-edge enabled + (re)started"

        # If the owner opted the auto-updater in, a reinstall must advance THAT
        # daemon too — otherwise a stale updater keeps running old code and future
        # pushes deadlock. Restart it ONLY when already enabled/active; never enable
        # a disabled updater here (it stays owner opt-in). The updater's own push
        # path runs update.sh, not this installer, so this can never self-kill.
        if systemctl is-enabled burrowee-edge-updater >/dev/null 2>&1 \
            || systemctl is-active burrowee-edge-updater >/dev/null 2>&1; then
            systemctl restart burrowee-edge-updater 2>/dev/null || true
            echo "restarted burrowee-edge-updater (opted in) to pick up new binary"
        fi
    fi
}

# Test seam: when sourced with this var set, stop here so a test harness can call
# the functions above without any install side-effect (tools/test-config-migrate.sh).
# shellcheck disable=SC2317  # the `|| exit 0` IS reached when this script is run (not sourced)
if [ -n "${BURROWEE_INSTALLER_SOURCE_ONLY:-}" ]; then return 0 2>/dev/null || exit 0; fi

# ---------------------------------------------------------------------------
# ROOT IS REQUIRED, and refused here — still before anything is placed, and
# before every mode below, because every one of them writes somewhere only root
# may write: /usr/local/bin, /etc/systemd/system, /Library/LaunchDaemons.
#
# The alternative is worse than an error. /usr/local is group-writable on an
# Intel Mac with Homebrew, so an unprivileged run would place the binaries, fail
# at the first unit write, and leave a half-installed edge with no service — and
# the binaries it did place would sit in a directory a non-root user can rewrite,
# which is exactly the standing uid-0 grant the root-owned destination exists to
# close.
#
# The refusal comes AFTER the source-only seam above: sourcing this file defines
# functions and places nothing, and tools/test-config-migrate.sh drives them as
# an ordinary user.
# ---------------------------------------------------------------------------
if ! is_root; then
    echo "install: this installer must run as root — it installs to /usr/local/bin and" >&2
    echo "install: manages a system service (systemd unit / launchd LaunchDaemon)." >&2
    echo "install: as of edge 0.2.0 there is no per-user install; nothing has been installed." >&2
    echo "hint: re-run with sudo, e.g." >&2
    echo "hint:   curl -fsSL https://release.burrowee.com/$COMP/install.sh | sudo sh" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Units-only mode (BURROWEE_UNITS_ONLY=1): the offline reinstall entrypoint run
# by edge's LocalReinstall. Re-render + reload the managed service units WITHOUT
# placing binaries or touching the network.
# ---------------------------------------------------------------------------
if [ -n "${BURROWEE_UNITS_ONLY:-}" ]; then
    setup_root_service
    echo "edge units-only reinstall: service units re-rendered + reloaded."
    exit 0
fi

if [ -n "${BURROWEE_UNINSTALL:-}" ]; then
    # Unconditional, like every other mode: there is one install shape left, and
    # it always has the managed system service.
    if [ "$(uname -s)" = "Darwin" ]; then
        launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null || true
        launchctl bootout "system/$LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
        rm -f "$LAUNCHD_PLIST" "$LAUNCHD_UPDATER_PLIST"
        remove_legacy_launchd_units
    else
        systemctl disable --now burrowee-edge 2>/dev/null || true
        systemctl disable --now burrowee-edge-updater 2>/dev/null || true
        rm -f "$SYSTEMD_UNIT" "$SYSTEMD_UPDATER_UNIT"
        systemctl daemon-reload 2>/dev/null || true
    fi
    removed=""
    for b in $BINS; do
        case "$b" in burrowee) continue ;; esac
        rm -f "$BIN_DIR/$b"
        removed="$removed $b"
    done
    # The bare `burrowee` dispatcher is SHARED across co-installed components
    # (e.g. a relay on the same host) — remove it only when no other
    # burrowee-* binary remains in $BIN_DIR.
    if ls "$BIN_DIR"/burrowee-* >/dev/null 2>&1; then
        echo "kept $BIN_DIR/burrowee (dispatcher) — other burrowee components remain installed"
    else
        rm -f "$BIN_DIR/burrowee"
        removed="$removed burrowee"
    fi
    echo "removed from $BIN_DIR:$removed"
    exit 0
fi

mkdir -p "$BIN_DIR"
for b in $BINS; do
    [ -f "./$b" ] || { echo "missing $b in archive" >&2; exit 1; }
    install -m 0755 "./$b" "$BIN_DIR/$b"
    if [ "$(uname -s)" = "Darwin" ]; then
        xattr -d com.apple.quarantine "$BIN_DIR/$b" 2>/dev/null || true
    fi
done
echo "installed to $BIN_DIR: $BINS"

# ---- state migrations -------------------------------------------------------
# Unconditional and a no-op unless a rung applies. See run_migration_ladder for
# why it sits exactly here: after the binaries, before the version anchor.
run_migration_ladder

# ---- cover assets (decoy pages for handleCover file mode) -------------------
# Always refresh the two SHIPPED defaults (admin.html + default.html) on every
# install/update: a stale hardcoded footer blows the decoy, so the shipped covers
# must track the release. Operator-added per-host <host>.html covers are not
# enumerated here, so they survive untouched (and still win in selectCover).
if [ -d "./covers" ]; then
    mkdir -p "$COMP_HOME/covers"
    for cf in admin.html default.html; do
        [ -f "./covers/$cf" ] || continue
        install -m 0644 "./covers/$cf" "$COMP_HOME/covers/$cf" 2>/dev/null \
            || cp "./covers/$cf" "$COMP_HOME/covers/$cf" 2>/dev/null \
            || echo "warning: could not install cover $cf" >&2
    done
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not on PATH — add: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

"$BIN_DIR/burrowee" --version 2>/dev/null || true

# ---- version-gated config migration ---------------------------------------
# Roll new default config onto existing installs (seed-if-absent), gated by the
# prior installed version. Best-effort; never aborts the install/update.
#
# $VERSION_MARKER is ALSO the migration ladder's anchor (migrations/run.sh reads
# it as $COMP_HOME/installed-version), which is why the write is withheld when a
# rung ran and could not be recorded: the receipt and the anchor are the two
# gates on a rung, and recording the version with the receipt lost closes the
# last one on work nothing can prove finished.
if [ -n "${BURROWEE_VERSION:-}" ]; then
    OLD_VER=""
    [ -f "$VERSION_MARKER" ] && OLD_VER="$(cat "$VERSION_MARKER" 2>/dev/null || true)"
    migrate_config "$OLD_VER" || echo "warning: config migration step failed; continuing" >&2
    mkdir -p "$COMP_HOME" 2>/dev/null || true
    if [ "$MIGRATE_UNRECORDED" = 1 ]; then
        report_unrecorded_migration
    elif printf '%s\n' "$BURROWEE_VERSION" > "$VERSION_MARKER.tmp" 2>/dev/null; then
        mv -f "$VERSION_MARKER.tmp" "$VERSION_MARKER" 2>/dev/null || echo "warning: could not record installed version" >&2
    else
        echo "warning: could not write version marker" >&2
    fi
fi

# Self-copy: keep a copy of this installer at $COMP_HOME/install.sh so an offline
# units-only reinstall (BURROWEE_UNITS_ONLY=1, run by edge's LocalReinstall) can
# re-render + reload the service units without a fresh download.
#
# THE MIGRATIONS GO WITH IT. This script resolves the runner and the sweep
# library relative to its OWN path, so a $COMP_HOME holding install.sh without
# migrations/ is an installer that silently cannot migrate and silently stops
# sweeping — both of which look exactly like a clean run.
mkdir -p "$COMP_HOME" 2>/dev/null || true
cp "$0" "$COMP_HOME/install.sh" 2>/dev/null || true
if [ -n "$MIGRATIONS_DIR" ] && [ "$MIGRATIONS_DIR" != "$COMP_HOME/migrations" ]; then
    mkdir -p "$COMP_HOME/migrations" 2>/dev/null || true
    cp "$MIGRATIONS_DIR"/* "$COMP_HOME/migrations/" 2>/dev/null \
        || echo "note: could not keep a copy of migrations/ at $COMP_HOME — a later" >&2
fi

# ---- the managed system service --------------------------------------------
# Every install sets up the managed root service running `burrowee-edge run` and
# (re)starts it, so the same one-liner is a fresh install AND an in-place update.
# There is no other install shape to fall through to: an unprivileged run was
# refused at the top, with nothing placed.
setup_root_service
# Only now: the binaries are in $SYS_BIN_DIR and the units naming them are
# not merely written but loaded. Deliberately NOT in BURROWEE_UNITS_ONLY
# mode above — that path places no binaries at all, so the precondition
# this sweep's safety rests on ("the new copies are already in place") is
# not something that mode establishes.
sweep_stale_user_bins
"$SYS_BIN_DIR/burrowee-edge" version 2>/dev/null || true
echo "edge system install complete."
# The managed service runs the daemon; pairing is a separate operator step:
#   burrowee edge cli bootstrap <blob> <pin>   (or via the console)
if [ ! -d "$COMP_HOME/identity" ] && [ ! -f "$COMP_HOME/console.json" ]; then
    # A host converging off the pre-collapse per-user layout may already own an
    # identity — under the operator's home, which this daemon does not read.
    note_orphaned_user_state
    echo "next: pair this edge — burrowee edge cli bootstrap <blob> <pin>"
fi
