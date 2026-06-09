#!/bin/sh
# Burrowee inner installer — gateway (POSIX sh).
#
# Ships at the ROOT of the verified release zip as `install.sh`. The outer
# bootstrap verifies the zip (minisign + sha256) and ONLY THEN execs this with
# cwd = the unzipped dir, so the binaries sit alongside this script. It installs
# them into PREFIX/bin (default $HOME/.local/bin). Set BURROWEE_UNINSTALL to
# remove them instead.
set -eu

BIN_DIR="${PREFIX:-$HOME/.local}/bin"
BINS="burrowee burrowee-gateway burrowee-register"
COMP=gateway

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

# ---- first-run bootstrap (interactive only) ----------------------------------
# Offer to bootstrap right after install. stdin is the curl pipe (not a tty), so
# read from the controlling terminal. Non-interactive (CI / no tty) just prints
# the next step. Reads are guarded so an EOF can't abort the install under set -e.
if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '\nSet up now? Paste the setup blob + PIN from the console (Enter to skip).\n' > /dev/tty
    printf 'blob> ' > /dev/tty
    blob=''; IFS= read -r blob < /dev/tty || blob=''
    if [ -n "$blob" ]; then
        printf 'pin>  ' > /dev/tty
        pin=''; IFS= read -r pin < /dev/tty || pin=''
        if [ -n "$pin" ]; then
            "$BIN_DIR/burrowee" "$COMP" bootstrap "$blob" "$pin" < /dev/tty || true
        else
            printf 'No PIN — skipped. Run later: burrowee %s bootstrap <blob> <pin>\n' "$COMP" > /dev/tty
        fi
    else
        printf 'Skipped. Run later: burrowee %s bootstrap <blob> <pin>\n' "$COMP" > /dev/tty
    fi
else
    echo "next: burrowee $COMP bootstrap <blob> <pin>"
fi
