#!/bin/sh
# tools/bootstrap-env-forwarding.test.sh — proves every BURROWEE_* variable an
# inner installer actually reads from its environment is forwarded across the
# `sudo env` elevation boundary in tools/bootstrap.template.sh. A variable
# read by inner/*/install.sh or inner/*/updater.install.sh but missing from
# the template's allow-list is a dead letter: it can be set by the caller,
# survives right up to `sudo`, and is silently scrubbed there.
#
#     sh tools/bootstrap-env-forwarding.test.sh          # this shell
#     dash tools/bootstrap-env-forwarding.test.sh         # and this one, always

set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$HERE/tools/bootstrap.template.sh"

consumed="$(grep -rhoE '\$\{?BURROWEE_[A-Z_]+' \
    "$HERE"/inner/*/install.sh "$HERE"/inner/*/updater.install.sh \
    | tr -d '${' | sort -u)"

FAIL=0
for v in $consumed; do
    case "$v" in
        # Set by the outer bootstrap template itself (run_inner's own
        # BURROWEE_VERSION="$TAG" assignment) — it is a producer, not a
        # forwarding target.
        BURROWEE_VERSION) continue ;;
        # Arrive only from the updater's own re-exec of the inner installer,
        # never from a bootstrap: the updater sets BURROWEE_UPDATE=1 and
        # BURROWEE_UNITS_ONLY=1 itself when it re-invokes install.sh
        # (edge/cmd/burrowee-edge-updater/subcommands_test.go:79 pins that
        # re-exec). No bootstrap path ever sets either.
        BURROWEE_UPDATE|BURROWEE_UNITS_ONLY) continue ;;
        # Test-only seams for the sandboxed installer harness, explicitly
        # documented as such where they're read (inner/gateway/install.sh
        # around :97-212, inner/edge/install.sh around :69) — "never set them
        # on a real host". A real bootstrap invocation never sets these, so
        # they have nothing to forward.
        BURROWEE_BIN_DIR|BURROWEE_LAUNCHD_DIR|BURROWEE_SYSTEMD_DIR| \
        BURROWEE_SYSTEM_CONFIG_DIR|BURROWEE_SYSTEM_DATA_DIR) continue ;;
        # Test seam: sourced-not-executed sentinel for a harness that wants
        # the script's functions without its side effects
        # (inner/edge/install.sh:696, "Test seam:"). Never set by a bootstrap.
        BURROWEE_INSTALLER_SOURCE_ONLY) continue ;;
        # Set by the Go side only, directly on the inner installer's own
        # invocation for `gateway update --force` (inner/gateway/install.sh
        # :1498, "set by the Go side only") — that call does not go through
        # this template at all.
        BURROWEE_FORCE) continue ;;
    esac
    if ! grep -q "$v=" "$TEMPLATE"; then
        echo "FAIL: $v is read by an inner script but never forwarded by $TEMPLATE"
        FAIL=1
    fi
done

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi

echo "ALL OK — every non-excluded BURROWEE_* variable read by an inner script is forwarded"
