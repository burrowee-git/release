#!/bin/sh
# tools/install-no-bootout.test.sh — pins the one invariant that makes the
# observed stranding unreachable: nothing in the gateway installer boots the
# SERVE label out.
#
#     sh tools/install-no-bootout.test.sh
#     dash tools/install-no-bootout.test.sh
#
# WHY. `launchctl bootout` UNLOADS a job. An unloaded job is not supervised —
# RunAtLoad and KeepAlive both describe a loaded job — so a shell that dies
# between the bootout and the bootstrap that was going to follow it leaves the
# daemon stopped with nothing that will ever restart it. On a gateway the shell
# dying is not hypothetical: the operator's session is tunnelled through the
# very daemon being booted out, so the bootout CAUSES the death.
#
# `launchctl kickstart -k` restarts a loaded job in place. It advances the job
# to the new binary without ever passing through an unloaded state, so there is
# no window for a dying shell to strand.
#
# THE UPDATER LABEL IS NOT COVERED. Booting the updater out does not sever
# anything, and its own installer has its own reload dance.
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
FILE="$HERE/inner/gateway/install.sh"
fails=0

fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

[ -f "$FILE" ] || { printf 'FATAL: %s not found\n' "$FILE" >&2; exit 1; }

# The serve label, booted out anywhere in the file.
if grep -n 'bootout .*system/com\.burrowee\.gateway"' "$FILE" \
   | grep -v 'updater' >/dev/null 2>&1; then
    fail "install.sh still boots out the serve label:"
    grep -n 'bootout .*system/com\.burrowee\.gateway"' "$FILE" | grep -v updater >&2
fi

# And the replacement must actually be present, or this suite passes vacuously
# on a file that simply stopped starting the service at all.
if ! grep -q 'kickstart -k' "$FILE"; then
    fail "install.sh contains no 'kickstart -k' — the comparison is vacuous"
fi

if [ "$fails" -ne 0 ]; then
    printf '%s: %d check(s) failed\n' "$0" "$fails" >&2
    exit 1
fi
printf 'ok: no serve-label bootout in inner/gateway/install.sh\n'
