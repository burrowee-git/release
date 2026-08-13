#!/bin/sh
# Burrowee inner installer — cli (POSIX sh).
#
# Ships at the ROOT of the verified release zip as `install.sh`. The outer
# bootstrap verifies the zip (minisign + sha256) and ONLY THEN execs this with
# cwd = the unzipped dir, so the binaries sit alongside this script. It installs
# them into PREFIX/bin (default $HOME/.local/bin). Set BURROWEE_UNINSTALL to
# remove them instead. Set BURROWEE_UNITS_ONLY=1 for the offline units-only
# reinstall (a no-op here — the cli lays no service unit).
set -eu

BIN_DIR="${PREFIX:-$HOME/.local}/bin"
BINS="burrowee burrowee-cli burrowee-cli-updater"
COMP=cli
COMP_HOME="$HOME/.burrowee/$COMP"

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

# Self-copy: keep a copy of this installer at $COMP_HOME/install.sh so an offline
# units-only reinstall (BURROWEE_UNITS_ONLY=1, run by cli's LocalReinstall) has a
# local installer to invoke. Written AFTER the setup check above so it never
# makes a fresh install look already-set-up.
mkdir -p "$COMP_HOME" 2>/dev/null || true
cp "$0" "$COMP_HOME/install.sh" 2>/dev/null || true
