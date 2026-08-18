#!/bin/sh
# Burrowee inner installer — cli (POSIX sh).
#
# Ships at the ROOT of the verified release zip as `install.sh`. The outer
# bootstrap verifies the zip (minisign + sha256) and ONLY THEN execs this with
# cwd = the unzipped dir, so the binaries sit alongside this script. It installs
# them into PREFIX/bin (default $HOME/.local/bin). Set BURROWEE_UNINSTALL to
# remove them instead. Set BURROWEE_UNITS_ONLY=1 for the offline units-only
# reinstall (a no-op here — the cli lays no service unit).
#
# THE MIGRATION LADDER. Since 0.2.0 this kit carries migrations/ — a runner
# shared with edge (authored once in inner/_shared/migrations and staged into
# both kits by tools/payload.sh), the component's own ledger, and the rungs the
# ledger names. It is walked UNCONDITIONALLY on every install and is a no-op
# unless a rung applies, so there is no second copy of the gate here.
#
# WHY THE CLI HAS ONE AT ALL, given that its 0.2.0 rung is a no-op on an
# ordinary cli host. The rung removes per-user binaries that SHADOW $BIN_DIR on
# PATH, and on a default cli install those are the same directory — the library
# refuses to sweep its own destination, so nothing applies and the ladder says
# so. It has work only on a cli whose $BIN_DIR is elsewhere (an explicit
# PREFIX). The ladder is here for the same reason the gateway's is: it is the
# only path a state change can take to a host the installer is run on, the
# version anchor below is what gates it, and adding the first rung that matters
# must not also mean adding the machinery to run it.
#
# THE DISPATCHER IS NOT THE CLI'S TO REMOVE UNILATERALLY. `burrowee` is shared
# by every co-installed component; the rule the shared library implements is
# that it goes only when no OTHER file in that directory matching burrowee-*
# carries the github.com/burrowee-git/ build stamp. A co-installed
# burrowee-gateway pins it; an operator's own `burrowee-notes` script does not.
set -eu

BIN_DIR="${PREFIX:-$HOME/.local}/bin"
BINS="burrowee burrowee-cli burrowee-cli-updater"
COMP=cli
COMP_HOME="$HOME/.burrowee/$COMP"
# The ladder's version anchor. Nothing wrote one before this ladder existed, so
# there is no name in the field to keep compatibility with; migrations/run.sh
# reads it as $COMP_HOME/$VERSION_FILE and migrations/component.conf in the cli
# repo declares the same spelling.
VERSION_MARKER="$COMP_HOME/.installed-version"

# Units-only mode (BURROWEE_UNITS_ONLY=1): the offline reinstall entrypoint run
# by cli's LocalReinstall. The cli lays NO service unit, so there is nothing to
# render or reload — this is a successful no-op that places no binaries and does
# not touch the network.
if [ -n "${BURROWEE_UNITS_ONLY:-}" ]; then
    echo "cli units-only reinstall: no service unit to render — nothing to do."
    exit 0
fi

if [ -n "${BURROWEE_UNINSTALL:-}" ]; then
    for b in $BINS; do rm -f "$BIN_DIR/$b"; done
    echo "removed from $BIN_DIR: $BINS"
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

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not on PATH — add: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

"$BIN_DIR/burrowee" --version 2>/dev/null || true

# ---- first-run bootstrap (interactive only, fresh installs) -------------------
# Re-install short-circuit: if this component already has persisted state under
# ~/.burrowee/<comp> (the gateway db/keys, cli/edge identity, …) it is already
# set up — never re-prompt for a setup blob. Otherwise read blob+PIN from the
# controlling terminal (stdin is the curl pipe, not a tty): prompt only if
# /dev/tty is genuinely usable (fd 3); if not (CI / detached) just print the
# next step. All tty I/O is fault-tolerant so it can never abort the install.
if [ -d "$COMP_HOME" ] && [ -n "$(ls -A "$COMP_HOME" 2>/dev/null || true)" ]; then
    echo "$COMP already set up ($COMP_HOME) — skipping setup."
elif ( exec 3<>/dev/tty ) 2>/dev/null; then
    # PROBED IN A SUBSHELL, then opened for real. dash treats a FAILED `exec`
    # redirection as fatal and exits the script — status 2, and the `2>/dev/null`
    # swallows the only message — even inside a guarded `{ …; }` used as an `if`
    # condition, because a brace group is not a subshell and so does not contain
    # the exit. /bin/sh IS dash on every Debian-family host, and this block is
    # the LAST step of an otherwise complete install, so on exactly the hosts
    # that matter the shape it replaces turned every non-interactive install
    # (CI, a console push, `curl … | sh` under a supervisor) into a fully
    # installed cli reporting failure — and skipped the self-copy below, which
    # LocalReinstall needs. A subshell contains the fatal exit, so the parent
    # survives to answer the question and then open fd 3 for real.
    exec 3<>/dev/tty
    printf '\nSet up now? Paste the setup blob + PIN from the console (Enter to skip).\n' >&3 2>/dev/null || true
    printf 'blob> ' >&3 2>/dev/null || true
    blob=''; IFS= read -r blob <&3 2>/dev/null || blob=''
    if [ -n "$blob" ]; then
        printf 'pin>  ' >&3 2>/dev/null || true
        pin=''; IFS= read -r pin <&3 2>/dev/null || pin=''
        if [ -n "$pin" ]; then
            "$BIN_DIR/burrowee" "$COMP" bootstrap "$blob" "$pin" <&3 || true
        else
            printf 'No PIN — skipped. Run later: burrowee %s bootstrap <blob> <pin>\n' "$COMP" >&3 2>/dev/null || true
        fi
    else
        printf 'Skipped. Run later: burrowee %s bootstrap <blob> <pin>\n' "$COMP" >&3 2>/dev/null || true
    fi
    exec 3>&- 2>/dev/null || true
else
    echo "next: burrowee $COMP bootstrap <blob> <pin>"
fi

# ---------------------------------------------------------------------------
# EVERYTHING BELOW RUNS AFTER THE FIRST-RUN SETUP CHECK, and that ordering is
# load-bearing rather than incidental. That check reads "$COMP_HOME is non-empty"
# as "this cli is already set up", so anything that creates $COMP_HOME earlier —
# the ladder's tree, the version anchor — would make every FRESH install look
# already-configured and silently skip the setup prompt. The self-copy below
# already carried that constraint; the ladder now shares it.
#
# Nothing here is destructive on a fresh host, so running it last costs only
# that a refusing ladder is reported after the prompt rather than before it.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# THE LADDER, then the installer's own sweep.
#
# MIGRATIONS_DIR is empty when this bundle carries none — a $COMP_HOME self-copy
# from an install predating the directory is exactly that, and it must still
# install rather than refuse. A bundle that HAS migrations/ and is missing a
# file inside it is the opposite case: a mis-assembled release, which this
# project has shipped once, and it is loud.
#
# ORDER: after the binaries are placed, before the version anchor is written.
# After, because the rung removes copies that shadow $BIN_DIR and removing them
# before the replacements exist would leave the operator's `burrowee` resolving
# to nothing for the length of an install. Before, because exit 3 means "the
# rung ran and its receipt was lost", and the only correct response is to
# withhold the anchor so the next install re-runs it — an anchor written first
# could not be withheld afterwards.
# ---------------------------------------------------------------------------
MIGRATIONS_DIR=""
if [ -d "$(dirname "$0")/migrations" ]; then
    MIGRATIONS_DIR="$(dirname "$0")/migrations"
fi

MIGRATE_UNRECORDED=0
if [ -n "$MIGRATIONS_DIR" ] && [ -f "$MIGRATIONS_DIR/run.sh" ]; then
    mkdir -p "$COMP_HOME" 2>/dev/null || true
    set +e
    COMP_HOME="$COMP_HOME" BIN_DIR="$BIN_DIR" sh "$MIGRATIONS_DIR/run.sh"
    _rc=$?
    set -e
    case "$_rc" in
    # 0 nothing applied · 2 migrations ran. This runner stops no service, so
    # there is nothing for this installer to start.
    0 | 2) ;;
    3) MIGRATE_UNRECORDED=1 ;;
    *)
        # 1 (refused/failed) or anything else is FATAL. Carrying on would write
        # the version anchor for a migration that refused, and the anchor is
        # what closes the gate on that rung permanently.
        echo "error: a state migration refused or failed — stopping." >&2
        echo "hint: the binaries are in $BIN_DIR; nothing else has been changed." >&2
        echo "hint: fix the cause reported above and re-run this installer." >&2
        exit 1
        ;;
    esac
fi

# The installer's OWN sweep, from the same shared library the rung uses. It
# stays here as well as being a rung, deliberately: a FRESH install must not
# depend on the ladder being coherent, the ladder is a no-op on a fresh host by
# construction, and the sweep is idempotent — running it twice costs a stat per
# name. install.sh runs only when somebody runs the installer and the updater
# never does, which is why the rung exists; the rung being new is not a reason
# to make fresh installs depend on it.
if [ -n "$MIGRATIONS_DIR" ]; then
    if [ -f "$MIGRATIONS_DIR/lib_stale_user_bins.sh" ] && [ -f "$MIGRATIONS_DIR/lib_paths.sh" ]; then
        # LIB_STALE_USER_BINS_DIR pins where the library finds its siblings.
        # Sourced from here, $0 is the BUNDLE ROOT and not migrations/, so
        # without this component.conf would never be found and the sweep would
        # silently have no names to sweep.
        LIB_STALE_USER_BINS_DIR="$MIGRATIONS_DIR"
        export LIB_STALE_USER_BINS_DIR
        # shellcheck source=/dev/null
        . "$MIGRATIONS_DIR/lib_paths.sh"
        # shellcheck source=/dev/null
        . "$MIGRATIONS_DIR/lib_stale_user_bins.sh"
        # THE TWO LISTS MUST AGREE. $BINS is what this installer PLACES;
        # $STALE_USER_BINS (from migrations/component.conf) is what the sweep
        # removes. A name in one and not the other is a binary installed and
        # never swept, or swept and never installed — and neither is visible
        # without saying so, because the sweep's normal output is nothing.
        if [ "$BINS" != "$STALE_USER_BINS" ]; then
            echo "note: this installer places [$BINS]" >&2
            echo "note: but $MIGRATIONS_DIR/component.conf sweeps [$STALE_USER_BINS]." >&2
            echo "note: the two lists disagree, so some name is installed and never swept" >&2
            echo "note: (it keeps shadowing $BIN_DIR on PATH) or swept and never installed." >&2
        fi
        remove_stale_user_bins
    else
        echo "note: $MIGRATIONS_DIR carries no lib_stale_user_bins.sh + lib_paths.sh pair —" >&2
        echo "note: THIS RELEASE IS INCOMPLETE. Stale per-user copies of these binaries are" >&2
        echo "note: NOT being swept. Re-run a complete release." >&2
    fi
fi

# ---- the migration ladder's version anchor ---------------------------------
# Withheld when a rung ran and could not be recorded: the receipt and the anchor
# are the two gates on a rung, and recording the version with the receipt lost
# closes the last one on work nothing on this host can prove finished.
if [ -n "${BURROWEE_VERSION:-}" ]; then
    mkdir -p "$COMP_HOME" 2>/dev/null || true
    if [ "$MIGRATE_UNRECORDED" = 1 ]; then
        echo "note: a migration completed but its receipt could not be written." >&2
        echo "note: the installed version is deliberately NOT recorded, so the next install" >&2
        echo "note: re-runs the migration (they are idempotent) rather than gating it off" >&2
        echo "note: on a version number with no receipt behind it." >&2
    elif printf '%s\n' "$BURROWEE_VERSION" > "$VERSION_MARKER.tmp" 2>/dev/null; then
        mv -f "$VERSION_MARKER.tmp" "$VERSION_MARKER" 2>/dev/null || echo "warning: could not record installed version" >&2
    else
        echo "warning: could not write version marker" >&2
    fi
fi

# Self-copy: keep a copy of this installer at $COMP_HOME/install.sh so an offline
# units-only reinstall (BURROWEE_UNITS_ONLY=1, run by cli's LocalReinstall) has a
# local installer to invoke. Written AFTER the setup check above so it never
# makes a fresh install look already-set-up.
mkdir -p "$COMP_HOME" 2>/dev/null || true
cp "$0" "$COMP_HOME/install.sh" 2>/dev/null || true
# THE MIGRATIONS GO WITH IT. This script resolves the runner and the sweep
# library relative to its OWN path, so a $COMP_HOME holding install.sh without
# migrations/ is an installer that silently cannot migrate and silently stops
# sweeping — both of which look exactly like a clean run.
if [ -n "$MIGRATIONS_DIR" ] && [ "$MIGRATIONS_DIR" != "$COMP_HOME/migrations" ]; then
    mkdir -p "$COMP_HOME/migrations" 2>/dev/null || true
    cp "$MIGRATIONS_DIR"/* "$COMP_HOME/migrations/" 2>/dev/null \
        || echo "note: could not keep a copy of migrations/ at $COMP_HOME" >&2
fi
