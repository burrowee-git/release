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
# THE PER-USER FLOW IS GONE, not de-defaulted. A PREFIX that would MISDIRECT the
# install is REFUSED, loudly (one that merely names this same destination is
# honoured and then cleared), and so is a run that never reached uid 0 — both
# before anything is placed,
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

# ── system install paths ─────────────────────────────────────────────────────
# SYS_BIN_DIR + SYSTEMD_UNIT_DIR + LAUNCHD_PLIST_DIR default to the real system
# locations; they are overridable only so the Go install-test harness can
# exercise this script in a sandbox without actually being root — never set them
# on a real host. SYS_BIN_DIR is this component's equivalent of the gateway's
# BURROWEE_BIN_DIR seam; it keeps its name because the rendered units, and every
# caller that already sets it, are written in terms of it.
#
# SYS_BIN_DIR and BIN_DIR are resolved BEFORE the PREFIX gate below, because the
# gate's whole question is "does this PREFIX name the destination we would have
# picked anyway?" — it cannot ask that without $BIN_DIR. These are assignments
# only: nothing is created, placed or written until well after the gate.
SYS_BIN_DIR="${SYS_BIN_DIR:-/usr/local/bin}"
# BIN_DIR and SYS_BIN_DIR are ONE destination under two names: the units and the
# test harness spell it SYS_BIN_DIR, the placement/uninstall code below spells it
# BIN_DIR, and since the 0.2.0 collapse they can never differ. Resolved HERE, at
# the top, rather than beside the config home further down — the shared sweep
# library reads $BIN_DIR for the guard that refuses to sweep the install
# destination, and a library sourced before the value was decided would have
# taken the production default while this run installed somewhere else.
BIN_DIR="$SYS_BIN_DIR"

# normalize_dir PATH — collapse repeated slashes and strip trailing ones, so
# '/usr/local/bin', '/usr/local//bin' and '/usr/local/bin/' all name the same
# directory. Root ('/') stays '/'. Used ONLY to compare two directory names.
#
# printf '%s', NEVER echo. dash's echo (and bash's under xpg_echo) expands
# backslash escapes in its argument, so an echo-based normaliser reduces
# PREFIX='/usr/local/bin\c' to '/usr/local/bin' and ACCEPTS a prefix that is not
# this destination at all — the one thing this gate exists to catch.
#
# TEXTUAL ONLY — no '.'/'..' folding, no symlink resolution, no relative-path
# anchoring. A PREFIX spelled '/usr/local/../local' or '/usr/local/.' is NOT
# recognised as the destination and is refused. Deliberate and sufficient: the
# one value this has to recognise is core's injected PREFIX, which is already
# filepath.Dir-clean and absolute, and a guard that resolved symlinks would be
# claiming to know where a path LANDS, which is a different (and racy) question
# from the one being asked here.
normalize_dir() {
    _nd="$(printf '%s' "$1" | sed -e 's|//*|/|g' -e 's|/*$||')"
    printf '%s' "${_nd:-/}"
}

# A DIVERGENT PREFIX IS REFUSED — a PREFIX that names THIS destination is not —
# and it is refused HERE, before a directory is created, a binary placed or a
# unit written. Refusing the divergent one is the point: an operator who typed
# PREFIX=$HOME/.local and got a root-owned /usr/local/bin would be handed exactly
# the class of surprise this collapse exists to remove, one direction reversed.
# They get told instead, and the process that set it (a shell profile, an outer
# bootstrap, a wrapper) is the thing that has to change. The version is named
# because the operator hitting this needs to know since when; it is asserted by
# the suite (install_test/root_only_test.go), so it cannot drift away from the
# release it describes without a test failing.
#
# But refusing EVERY set PREFIX refuses callers that are naming the one true
# destination, which misdirects nothing — and that blanket shape is what wedged
# relay's entire fleet on 2026-08-22: core's updater injects
# PREFIX=<dirname²(ServeBin)> = /usr/local when it runs these scripts, so every
# auto/push update died with "PREFIX is set to '/usr/local' … nothing has been
# updated". Today this installer survives that only because core strips PREFIX
# for root-only components before exec — i.e. the fresh-install path is protected
# by a Go change rather than by the rule. The rule is the guard's subject: a copy
# landing where the units never execute, and only that.
if [ -n "${PREFIX:-}" ]; then
    _prefix_bin="$(normalize_dir "$PREFIX/bin")"
    _true_bin="$(normalize_dir "$BIN_DIR")"
    if [ "$_prefix_bin" = "$_true_bin" ]; then
        # printf, not echo, for every line that interpolates the caller's own
        # value: dash's echo would expand a backslash escape inside $PREFIX and
        # silently truncate the very line meant to quote it back.
        printf '%s\n' "install: PREFIX ('$PREFIX') names this installer's own destination ($_true_bin) — proceeding."
        # Absent, not empty: an ACCEPTED PREFIX is cleared right here, so nothing
        # downstream can read it as a fallback. The migration ladder is handed
        # its environment with the `VAR=x sh run.sh` form, which ADDS to the
        # environment rather than replacing it, and the shared rungs read
        # BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}" — harmless only while
        # BIN_DIR is passed explicitly and wins, i.e. one deletion away from
        # mattering. Cleared, never set to "": absent, not empty, as core does it.
        unset PREFIX
    else
        # The refusal carries BOTH spellings of the destination: the literal
        # /usr/local/bin (production truth, and what the suite's static pins
        # check) and the resolved $_true_bin. They differ only when the
        # SYS_BIN_DIR test seam is set, and an operator reading a refusal on a
        # real host must see the real path either way.
        #
        # printf, not echo, on the two lines that interpolate caller-controlled
        # text: a PREFIX containing a backslash escape ('\c' ends echo's output
        # in dash) would otherwise truncate the refusal at the moment it quotes
        # the offending value, hiding the component, the destination and the
        # "nothing has been installed" line all at once.
        printf '%s\n' "install: PREFIX is set to '$PREFIX', but as of edge 0.2.0 this installer" >&2
        echo "install: has one destination: /usr/local/bin, root-owned. The per-user prefix" >&2
        echo "install: flow is gone — edge's service units run as root and name the binaries" >&2
        echo "install: absolutely, and other components resolve /usr/local/bin/burrowee by" >&2
        echo "install: absolute path, so a per-user copy is invisible to both." >&2
        printf '%s\n' "install: (a PREFIX resolving to $_true_bin is honoured; '$_prefix_bin' is not it.)" >&2
        echo "hint: unset PREFIX and re-run; nothing has been installed." >&2
        exit 1
    fi
    unset _prefix_bin _true_bin
fi

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
    # Both roots exist by now (ensure_system_roots, before anything is placed),
    # and the runner is handed BOTH: for a `system`-scheme component it refuses a
    # $COMP_HOME without a $COMP_DATA rather than pairing a named tree with a
    # defaulted one, which is what keeps the installer and the ladder from
    # describing two different installs.
    set +e
    COMP_HOME="$COMP_HOME" \
        COMP_DATA="$COMP_DATA" \
        SYS_CONFIG_ROOT="$SYS_CONFIG_ROOT" \
        SYS_DATA_ROOT="$SYS_DATA_ROOT" \
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
        echo "error: units are written and the binaries are in $BIN_DIR." >&2
        # NOT "nothing else has been changed": edge declares
        # SERVICE_STOP_RUNGS="adopt_user_tree.sh", so a rung MAY have stopped the
        # daemon before the ladder failed. The runner says on stderr when it did;
        # this message must not contradict that by claiming the host is untouched,
        # and must not claim the stop happened either — re-running the installer
        # is the fix in both cases, and the start command is here for an operator
        # who needs the daemon up before that.
        echo "error: a migration may have STOPPED the $COMP service before failing —" >&2
        echo "error: check the runner's output above." >&2
        if [ "$(uname -s)" = "Darwin" ]; then
            echo "hint: start it with: sudo launchctl kickstart -k system/$LAUNCHD_LABEL" >&2
        else
            echo "hint: start it with: sudo systemctl start burrowee-edge" >&2
        fi
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

# note_orphaned_user_state — REPORT, and never touch, a home-shaped config tree
# that holds this host's pairing while the managed service reads elsewhere.
#
# TWO CANDIDATES, the same two the adoption rung takes its source from: ROOT's
# ~/.burrowee/edge (a 0.2.0 host, from the collapse or from the manual copy made
# during the outage) and the OPERATOR's (a pre-collapse host). Neither travels
# with the binaries, so a host converging onto the machine-owned roots comes up
# as a healthy, running, UNPAIRED edge. Silence is the worst outcome available
# here: the install exits 0, the service is up, and nothing gives the operator a
# reason to look for the identity that already exists a directory away.
#
# Says nothing when there is no such state. That $COMP_HOME is unpaired is the
# CALLER's condition — this is only reached from the "next: pair this edge"
# branch — and it is not re-tested here: a second copy of a condition its only
# call site already decided cannot fail independently, it can only drift.
#
# It resolves both homes through the SAME operator_home/root_home the sweep and
# the ladder use — one definition, in migrations/lib_paths.sh — so the directory
# it reports on and the directory the rung would act on can never be two
# different answers. With no library loaded it says nothing rather than guessing
# $HOME, which under `sudo sh` is root's: a report naming the wrong directory is
# worse than no report, because it is acted on.
note_orphaned_user_state() {
    [ "$SWEEP_LIB_LOADED" = 1 ] || return 0
    _nos_seen=""
    for _nos_dir in "$(root_home)/.burrowee/$COMP" "$(operator_home)/.burrowee/$COMP"; do
        [ -n "$_nos_dir" ] || continue
        case "$_nos_dir" in "/.burrowee/$COMP") continue ;; esac
        [ "$_nos_dir" = "$COMP_HOME" ] && continue
        [ "$_nos_dir" = "$COMP_DATA" ] && continue
        case " $_nos_seen " in *" $_nos_dir "*) continue ;; esac
        _nos_seen="$_nos_seen $_nos_dir"
        [ -d "$_nos_dir/identity" ] || [ -f "$_nos_dir/console.json" ] || continue
        echo "note: $_nos_dir holds a paired edge identity from an earlier install," >&2
        echo "note: but the managed service reads $COMP_HOME — this edge starts UNPAIRED." >&2
        echo "hint: the migration ladder adopts it (root's tree first when both exist);" >&2
        echo "hint: force it with  sh $COMP_HOME/migrations/upgrade.sh 0.2.0" >&2
        echo "hint: or pair again (burrowee $COMP cli bootstrap <blob> <pin>). Nothing was removed." >&2
    done
}

# ── the one install target ───────────────────────────────────────────────────
# The service's config home. $BIN_DIR was decided at the top of this file,
# beside $SYS_BIN_DIR — there is no branch left to take, so every step below
# that only made sense for a root install (setup_root_service, the unit teardown
# on uninstall, the stale-bin sweep, the version marker under root's home) now
# runs on EVERY install.
#
# TWO MACHINE-OWNED ROOTS, not root's home. Spec
# 2026-08-13-burrowee-root-install-shared-cli-design §3 gave edge the system
# roots at the same time it gave them to the gateway; 0.2.0 shipped the binary
# move without the layout and the daemon kept reading
# $ROOT_HOME/.burrowee/edge — i.e. whichever home the supervisor exported.
#
#   $COMP_HOME  /usr/local/etc/burrowee/edge  config: identity/, console.json,
#               the operator's `config`, bridge/, host-cert/, lan-cert/,
#               cf-token, installed-version, migration-receipts/, migrations/,
#               this installer's self-copy. Backed up, never cleared.
#   $COMP_DATA  /usr/local/var/burrowee/edge  state: config.json, logs/, stats/,
#               covers/, running.json. Rewritten while the daemon serves and
#               reclaimable.
#
# SYS_CONFIG_ROOT / SYS_DATA_ROOT are overridable only for the Go install-test
# harness, like SYS_BIN_DIR. They are NOT a supported operator knob and no
# shipped unit names anything derived from them but these two paths.
SYS_CONFIG_ROOT="${SYS_CONFIG_ROOT:-/usr/local/etc/burrowee}"
SYS_DATA_ROOT="${SYS_DATA_ROOT:-/usr/local/var/burrowee}"
COMP_HOME="$SYS_CONFIG_ROOT/$COMP"
COMP_DATA="$SYS_DATA_ROOT/$COMP"
VERSION_MARKER="$COMP_HOME/installed-version"

# ---------------------------------------------------------------------------
# The post-start daemon wait (see wait_for_running_version, and the tail of this
# script). WAIT_CEILING is a CEILING, not a sleep: the wait returns the instant
# the daemon reports the version being installed, and $WAIT_INTERVAL is only how
# often it looks.
#
# Overridable for the shell test harnesses, exactly like SYS_BIN_DIR above, and
# for nothing else — an operator has no reason to retune this and no documented
# knob to do it with. Deliberately NOT spelled BURROWEE_*: those are the
# published knobs the bootstrap forwards across its sudo boundary
# (tools/bootstrap-env-forwarding.test.sh), and these two are not published.
#
# SERVE_UNIT_STARTED is the wait's gate — 1 only once the SERVE unit has been
# (re)started AND verified up by start_unit_darwin / start_unit_linux. There is
# nothing to wait for when nothing was restarted — which includes a mode that
# stages the units without starting them, and only ONE of the three components
# sharing this block has one: gateway reads BURROWEE_NO_RESTART, edge and relay
# read it nowhere, so for them the gate is the start itself and nothing else.
# Nor when the start already failed: that path has already said so, and spending
# the ceiling to rediscover a known failure is noise on top of it. A started
# UPDATER never sets it — a live updater says nothing about the daemon that
# serves.
# ---------------------------------------------------------------------------
WAIT_INTERVAL="${WAIT_INTERVAL:-2}"
WAIT_CEILING="${WAIT_CEILING:-60}"
SERVE_UNIT_STARTED=0

# $ROOT_HOME is still resolved, and it is no longer where anything lives. The
# units set HOME=$ROOT_HOME (below) purely so a library that dereferences $HOME
# has a real directory to find: systemd exports none to a root unit and launchd
# exports none at all, and os.UserHomeDir() then fails with "$HOME is not
# defined" — which on the gateway killed the updater agent on every start until
# the supervisor gave up. Nothing about edge's config or state is derived from
# it any more; internal/edgeroot resolves both roots without consulting $HOME.
# The stale-tree note and the adoption rung still name it, because it is one of
# the two places an already-enrolled host's state may currently be.
#
# root_home() from migrations/lib_paths.sh is the ONE implementation of that
# rule, shared with the migration runner. The inline fallback below is reached
# only by a bundle that carries no migrations/ at all — a $COMP_HOME self-copy
# predating the directory, which only BURROWEE_UNITS_ONLY runs — and it is
# deliberately the same rule rather than a simplification of it.
if command -v root_home >/dev/null 2>&1; then
    ROOT_HOME="$(root_home)"
elif [ "$(uname -s)" = "Darwin" ]; then
    ROOT_HOME="${ROOT_HOME:-$(eval echo ~root)}"
    case "$ROOT_HOME" in /*) ;; *) ROOT_HOME=/var/root ;; esac
else
    ROOT_HOME="${ROOT_HOME:-/root}"
fi

# ---------------------------------------------------------------------------
# ensure_system_roots — create both machine-owned roots, root-owned and 0700.
#
# A NON-ROOT PROCESS MUST NEVER BE THE ONE TO CREATE THEM: on a host where
# /usr/local is writable by the installing user (Intel macOS, where Homebrew
# chowns it) an unprivileged mkdir succeeds and leaves the root daemon writing
# identity/relay_ed.key — whose pubkey IS this node's fingerprint — and the
# host-cert private key inside a directory that user fully controls. Edge's
# installer is root-only, so is_root is the whole check; a non-root run refuses
# here rather than half-creating the pair.
#
# 0700 on the component roots, 0755 on the shared PARENTS. /usr/local/etc/burrowee
# is the gateway's parent too, and the gateway's console.token carries a 0640
# root:<admin-group> grant that a 0700 parent would silently revoke — a mode
# nobody reading that file could detect. The parents are only moded when THIS
# run created them; one that already exists belongs to whoever made it.
#
# The mode is set explicitly rather than left to mkdir's argument because
# mkdir -p applies the process umask: under 022 a 0700 argument still yields
# 0755, and under 077 a 0755 argument yields 0700.
# ---------------------------------------------------------------------------
ensure_system_roots() {
    if ! is_root; then
        echo "error: $0 must run as root — it creates $COMP_HOME and $COMP_DATA," >&2
        echo "error: and whatever an unprivileged process creates, that user owns." >&2
        exit 1
    fi
    for _esr_root in "$SYS_CONFIG_ROOT" "$SYS_DATA_ROOT"; do
        if [ ! -d "$_esr_root" ]; then
            mkdir -p "$_esr_root" || { echo "error: could not create $_esr_root" >&2; exit 1; }
            chmod 0755 "$_esr_root" 2>/dev/null || true
        fi
    done
    for _esr_dir in "$COMP_HOME" "$COMP_DATA"; do
        mkdir -p "$_esr_dir" || { echo "error: could not create $_esr_dir" >&2; exit 1; }
        chmod 0700 "$_esr_dir" 2>/dev/null || true
    done
}

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

# $_RUNROOT / $_SYSTEMCTL — the two seams the start helpers below are
# parameterised on. Those bodies are byte-identical across the four inner
# installers and pinned that way (tools/prefix-gate-drift.test.sh), so anything
# that legitimately differs between them has to be a variable read by the body,
# never an edit to the body — and never a wrapper at the call site either, since
# `$_RUNROOT cmd` with _RUNROOT=run_root expands to a function call and a call
# site cannot reach inside the helper's own launchctl/systemctl invocations.
#
# This installer refuses to run as anything but root (the is_root gate further
# down, which exits 1 before a single binary is placed), so there is nothing to
# elevate through: the prefix is empty and `$_RUNROOT launchctl …` expands to
# `launchctl …`. It declares no $SYSTEMCTL seam either.
_RUNROOT=""
_SYSTEMCTL="systemctl"

# start_unit_darwin <label> <plist> — start a launchd system unit and verify it
# took. bootstrap's codes 5 (already loaded) and 37 are benign races against an
# async bootout — every other code is a real failure and must not be swallowed.
# enable + kickstart ALWAYS run: a bootstrap that no-ops on an already-loaded
# label still needs both.
#
# The status is captured with `|| _rc=$?`, NOT inside `if ! ...`: POSIX makes $?
# the NEGATED status of a `!` pipeline, so an `if !` branch would read 0 for
# every failure and tolerate nothing.
#
# EVERY launchctl CALL GOES THROUGH $_RUNROOT, and that is not decoration. Only
# one of the four scripts carrying this body refuses to run as anything but
# root; the other three are entered by an unprivileged shell and elevate per
# command. Unprivileged on macOS, `launchctl bootstrap` exits 5 — a code the
# case below TOLERATES as "already loaded" — and `launchctl print` exits 113, so
# a bare-launchctl body would sail past the guard, have enable and kickstart
# denied and swallowed, and then abort at the probe with the daemon already
# booted out by the caller. Silent non-elevation is the one failure this helper
# cannot see.
start_unit_darwin() {
    _label="$1"; _plist="$2"
    _rc=0
    $_RUNROOT launchctl bootstrap system "$_plist" 2>/dev/null || _rc=$?
    case "$_rc" in
        0 | 5 | 37) ;; # started / already loaded / async bootout still settling
        *)
            echo "error: launchctl bootstrap $_label failed (exit $_rc)" >&2
            echo "hint: sudo launchctl bootstrap system $_plist" >&2
            return 1
            ;;
    esac
    # enable + kickstart ALWAYS run, and their failures are deliberately funnelled
    # into the probe below rather than aborting under set -e: the probe is the only
    # thing that reports the label and a recovery command. `|| true` is safe here
    # ONLY because a verification immediately follows it — never widen it further.
    $_RUNROOT launchctl enable "system/$_label" 2>/dev/null || true
    $_RUNROOT launchctl kickstart -k "system/$_label" 2>/dev/null || true
    if $_RUNROOT launchctl print "system/$_label" >/dev/null 2>&1; then
        echo "launchd service $_label enabled + started"
    else
        echo "error: $_label did not come up after bootstrap" >&2
        echo "hint: sudo launchctl print system/$_label" >&2
        return 1
    fi
}

# start_unit_linux <unit> — enable, (re)start and verify a systemd system unit.
# The probe is the point: enable --now on a unit that then dies must not be
# reported as a started service.
#
# $_RUNROOT for the same reason as start_unit_darwin above; $_SYSTEMCTL because
# two of the four scripts carrying this body declare a $SYSTEMCTL test seam and
# still route every other systemctl call through it — a bare `systemctl` here
# would be the one call that escaped it.
start_unit_linux() {
    _unit="$1"
    # Failures here are funnelled into the is-active probe below rather than
    # aborting under set -e: the probe is the only thing that reports the unit and
    # a recovery command. `|| true` is safe here ONLY because a verification
    # immediately follows it — never widen it further.
    $_RUNROOT "$_SYSTEMCTL" enable --now "$_unit" 2>/dev/null || true
    $_RUNROOT "$_SYSTEMCTL" restart "$_unit" 2>/dev/null || true
    if $_RUNROOT "$_SYSTEMCTL" is-active --quiet "$_unit"; then
        echo "systemd service $_unit enabled + (re)started"
    else
        echo "error: $_unit is not active after enable --now" >&2
        echo "hint: sudo $_SYSTEMCTL status $_unit" >&2
        return 1
    fi
}

# binary_version_stamp <binary> — the version token a binary reports for ITSELF,
# or "" when it cannot be read.
#
# THIS, and not $BURROWEE_VERSION, is what the wait below compares against,
# because it is literally the same string the daemon writes: core's
# runtime_version.WriteRunning records the serve binary's `version` variable, and
# `<bin> version` prints that same variable as its first version-shaped token
# (the parse runtime_version.InstalledVersion does, in shell). $BURROWEE_VERSION
# is the release tag the bootstrap resolved, and it is empty whenever an operator
# runs an unpacked kit by hand.
#
# BURROWEE_DISPATCHER_VERSION is blanked for the probe, exactly as
# InstalledVersion strips it: inherited, the binary prints a dispatcher row
# FIRST, and the first token would be the dispatcher's stamp rather than this
# binary's.
binary_version_stamp() {
    # BOUNDED, because this runs the freshly-placed SERVE binary and an
    # unbounded `version` on a binary that hangs hangs the installer — with no
    # ceiling and no message, at the step whose whole job is to report. The Go
    # original of this probe (core runtime_version) bounds the same command at
    # 2s; this is that bound.
    #
    # THERE IS NO TIMEOUT HELPER IN THESE SCRIPTS TO REUSE, and acquiring a hard
    # dependency for one probe is the wrong trade — as is the shell-only
    # substitute, which cannot tell a finished child from a zombie and so pays
    # its ceiling on EVERY install. So the bound is applied where the host
    # already has it (`timeout`, GNU coreutils, present on every Linux host;
    # `gtimeout`, the same tool where a macOS host installed coreutils) and is
    # absent otherwise, leaving today's behaviour exactly as it is. A stock
    # macOS host is therefore still unbounded here — a known, stated gap, not an
    # oversight.
    _bvs_bound=""
    if command -v timeout >/dev/null 2>&1; then
        _bvs_bound="timeout 2"
    elif command -v gtimeout >/dev/null 2>&1; then
        _bvs_bound="gtimeout 2"
    fi
    # shellcheck disable=SC2020  # the repeated '\n' is deliberate: BOTH space and tab map to a newline.
    # shellcheck disable=SC2086  # $_bvs_bound is a command PREFIX and must word-split; empty means no bound.
    BURROWEE_DISPATCHER_VERSION="" $_bvs_bound "$1" version 2>/dev/null \
        | tr ' \t' '\n\n' \
        | grep -E '^v?[0-9]+(\.[0-9]+){0,5}(\.[0-9a-f]+)?$' \
        | head -n 1
}

# wait_for_running_version <running-json-dir> <expected-version> — block until
# the daemon reports it is serving <expected-version>, polling every
# $WAIT_INTERVAL seconds up to $WAIT_CEILING.
#
# running.json is written BY THE DAEMON at serve start (core
# runtime_version.WriteRunning) and carries {"version","pid","started_at"}, so a
# match is positive proof the NEW binary is the one serving. The installed-version
# marker is NOT usable as this predicate: THIS script writes it, so comparing it
# to the version being installed matches instantly — including on a host where
# the daemon never started, which is the only case worth asking about.
#
# The sed parse is deliberate, not laziness. running.json is json.Marshal of a
# flat three-field struct: no nesting, no indentation, and nothing escapable in a
# release stamp. An installer does not acquire a JSON dependency for that.
#
# BEST-EFFORT BY CONTRACT: a timeout warns and returns 1, and the caller ignores
# that status. "Did the unit come up at all" was already answered by
# start_unit_*, which fails the install. This is the softer second question — the
# unit is active, but is it serving the NEW binary? — and an operator whose
# daemon is slow to bind must not have a finished install fail retroactively.
wait_for_running_version() {
    _dir="$1"; _want="$2"; _waited=0
    while [ "$_waited" -lt "$WAIT_CEILING" ]; do
        _got="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            "$_dir/running.json" 2>/dev/null || true)"
        if [ -n "$_got" ] && [ "$_got" = "$_want" ]; then
            echo "daemon is serving $_want (after ${_waited}s)"
            return 0
        fi
        sleep "$WAIT_INTERVAL"
        _waited=$((_waited + WAIT_INTERVAL))
        echo "  waiting for the daemon to report $_want … ${_waited}s/${WAIT_CEILING}s"
    done
    echo "warning: the daemon did not report version $_want within ${WAIT_CEILING}s" >&2
    echo "hint: it may still be starting; 'doctor' below reports the live state" >&2
    return 1
}

# setup_root_service — render BOTH managed SYSTEM service units for the host init
# system and (re)load BOTH of them: the serve unit always, the updater unit
# unless BURROWEE_NO_UPDATER is set. Root-only caller. Renders unit FILES
# pointing at $SYS_BIN_DIR; it never places binaries, so it is safe to call from
# the units-only reinstall path as well as fresh install / update.
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

        # Updater LaunchDaemon (mirrors the systemd updater unit; HOME so its
        # console.json + identity resolve under $ROOT_HOME/.burrowee/edge).
        # Started below unless BURROWEE_NO_UPDATER is set — the auto-updater is
        # opt-OUT: an install leaves it running so the host keeps receiving fixes.
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
        echo "wrote LaunchDaemon → $LAUNCHD_UPDATER_PLIST"

        # Migrate away the pre-rename org.burrowee.* units before loading the
        # com.burrowee.* ones — two labels must never run the same daemon.
        remove_legacy_launchd_units

        launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null || true
        start_unit_darwin "$LAUNCHD_LABEL" "$LAUNCHD_PLIST"
        # Reached only when the serve unit verified up: start_unit_darwin returns
        # non-zero otherwise, and under `set -e` that ends this script. The flag
        # is therefore the honest answer to "is there a daemon to wait for", and
        # it is the ONLY thing that arms the post-start wait at the tail.
        SERVE_UNIT_STARTED=1

        # The updater starts with the serve unit — it is the only automatic
        # delivery channel, so an install that leaves it down leaves the host
        # unreachable by fixes. BURROWEE_NO_UPDATER=1 stages the unit without
        # starting it, for an owner who pins deliberately. A reinstall restarts
        # it either way, so a stale updater cannot keep running old code and
        # deadlock future pushes; the updater's own push path runs update.sh, not
        # this installer, so this can never self-kill.
        if [ -n "${BURROWEE_NO_UPDATER:-}" ]; then
            echo "note: BURROWEE_NO_UPDATER set — updater unit staged, not started" >&2
        else
            launchctl bootout "system/$LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
            start_unit_darwin "$LAUNCHD_UPDATER_LABEL" "$LAUNCHD_UPDATER_PLIST"
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
        # console.json + identity resolve to /root/.burrowee/edge). Started below
        # unless BURROWEE_NO_UPDATER is set — the auto-updater is opt-OUT: an
        # install leaves it running so the host keeps receiving fixes.
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
        echo "wrote systemd unit → $SYSTEMD_UPDATER_UNIT"

        systemctl daemon-reload
        start_unit_linux burrowee-edge
        # See the Darwin branch: reached only on a verified start, and the only
        # thing that arms the post-start wait.
        SERVE_UNIT_STARTED=1

        # The updater starts with the serve unit — it is the only automatic
        # delivery channel, so an install that leaves it down leaves the host
        # unreachable by fixes. BURROWEE_NO_UPDATER=1 stages the unit without
        # starting it, for an owner who pins deliberately. A reinstall restarts
        # it either way, so a stale updater cannot keep running old code and
        # deadlock future pushes; the updater's own push path runs update.sh, not
        # this installer, so this can never self-kill.
        if [ -n "${BURROWEE_NO_UPDATER:-}" ]; then
            echo "note: BURROWEE_NO_UPDATER set — updater unit staged, not started" >&2
        else
            start_unit_linux burrowee-edge-updater
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
    echo "install: the published installer elevates on its own — you are seeing this" >&2
    echo "install: because you ran an unpacked kit directly. Either:" >&2
    echo "hint:   sudo sh ./install.sh                                   # this kit" >&2
    echo "hint:   curl -fsSL https://release.burrowee.com/$COMP/install.sh | sh   # the channel" >&2
    exit 1
fi

# Both machine-owned roots, before anything is placed and before the ladder is
# asked about them. Deliberately AFTER the source-only seam above: sourcing this
# file defines functions and creates nothing, which is what lets
# tools/test-config-migrate.sh drive them as an ordinary user.
ensure_system_roots

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
# The DATA root: a cover page is shipped content the installer re-places on
# every run, not something an operator reconstructs.
if [ -d "./covers" ]; then
    mkdir -p "$COMP_DATA/covers"
    for cf in admin.html default.html; do
        [ -f "./covers/$cf" ] || continue
        install -m 0644 "./covers/$cf" "$COMP_DATA/covers/$cf" 2>/dev/null \
            || cp "./covers/$cf" "$COMP_DATA/covers/$cf" 2>/dev/null \
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

# ---------------------------------------------------------------------------
# Prove the NEW daemon is serving, then report — the last thing this script does
# on the full-install path, because "hands back" is where the claim is made.
#
# THE PATH. burrowee-edge writes running.json into the DATA tree, not the config
# tree: cmd/burrowee-edge/config.go's recordRunningVersion is
# runtime_version.WriteRunning(edgeData(), version), and edgeData() is
# edgeroot.DataDirFor(edgeHome()) — $COMP_DATA here, never $COMP_HOME. That
# function is named rather than inlined for exactly this reason, and its header
# records what the second spelling cost: a doctor reporting "the daemon is not
# running" about a daemon that was, for 35h on a production node. These two names
# must stay in step; tools/install-waits-for-daemon.test.sh asserts they do.
#
# Not on the BURROWEE_UNITS_ONLY path above: that mode places no binaries, so
# there is no version being installed to wait for.
# ---------------------------------------------------------------------------
if [ "$SERVE_UNIT_STARTED" = 1 ]; then
    WANT_VERSION="$(binary_version_stamp "$SYS_BIN_DIR/burrowee-edge")"
    if [ -n "$WANT_VERSION" ]; then
        # The timeout's status is deliberately dropped: this wait never fails an
        # install (see wait_for_running_version's contract).
        wait_for_running_version "$COMP_DATA" "$WANT_VERSION" || true
    else
        echo "note: could not read the installed binary's version stamp — not waiting" >&2
    fi
else
    echo "note: the serve unit was not (re)started by this run — not waiting on it"
fi

# ---- doctor, unconditionally ------------------------------------------------
# On the match path, the timeout path and the skipped path alike. The wait
# answers one bit; doctor is the report an operator acts on, and after a timeout
# it is the only thing that says what the daemon is actually doing.
#
# ITS EXIT STATUS IS NOT THIS INSTALL'S. The verdict was decided by start_unit_*
# further up; a read-only `doctor` exits 3 when it finds failing rows, which is a
# diagnostic doing its job and not a failed install. Hence the guard.
#
# STDIN IS /dev/null so it can neither prompt nor elevate. doctor's elevation
# gate is `euid != 0 && stdin is a terminal` (mayElevateFn,
# cmd/burrowee-edge-cli/doctor_elevate.go), and a non-terminal stdin makes it
# false whoever is running — this script is already root, but the redirect is
# what makes that structural rather than incidental. Only `--fix` remediates or
# prompts, and this is the read-only verb.
"$SYS_BIN_DIR/burrowee-edge-cli" doctor < /dev/null || true
