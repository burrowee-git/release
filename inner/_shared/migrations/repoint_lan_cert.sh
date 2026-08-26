#!/bin/sh
# _shared/migrations/repoint_lan_cert.sh — repoint a lan_cert that still names
# the tree the 0.2.0 adoption retired. Target version 0.2.11 (see the
# component's migrations/ledger).
#
# ONE STEP IN THE LADDER. run.sh owns the version gate, the receipt and the
# ordering; this script owns only the repoint.
#
# THE DEFECT IT REPAIRS. adopt_user_tree.sh carries `config` byte-for-byte, and
# lan_cert inside it is an ABSOLUTE path into the SOURCE tree — which that same
# rung renames to `<tree>.bak.<stamp>` once the copy verifies. The adopted
# daemon then reads a cert directory that no longer exists, aborts the serve
# (cmd/burrowee-edge/run.go), and the service manager runs the abort as a crash
# loop. Seen on one host twice, 2026-08-21 and 2026-08-26.
#
# THE CERT PAIR IS ALREADY HERE. lan-cert/cert.pem and lan-cert/key.pem are both
# in the adoption's carried set, so the files reached $COMP_HOME and only the
# pointer is wrong. That is the whole repair: one value, rewritten to name the
# pair that is already on disk.
#
# IT NEVER MINTS A REPLACEMENT. Every peer trusts this cert BY FINGERPRINT, so a
# freshly generated pair is not a repaired edge — it is a silently un-trusted one
# whose peers must all be re-pinned. With no pair at the canonical name this rung
# does NOTHING and says so; minting is an operator's decision
# (`burrowee <comp> nginx reconcile --mode lan`), never a migration's.
#
# WHY A NEW ROW RATHER THAN A STEP FOLDED INTO adopt_user_tree.sh. The gate is
# "recorded < target", so adding work to the shipped 0.2.0 line would strand
# every host that already crossed it — their anchor honestly says "past it", and
# the gate cannot tell "migrated at 0.2.0" from "crossed 0.2.0 when the migration
# was smaller". Those hosts are exactly the ones carrying this defect. A row at
# 0.2.11 reaches them on their next upgrade with no forcing.
#
# MODES
#   --applies   exit 0 if this host still needs the repoint.
#   (no args)   perform it.
#
# IT RE-DECIDES AT THE MOMENT IT WRITES rather than trusting the probe that
# selected it: the gate is per ITEM, and the one item here re-tests its own
# applicability where it runs.
#
# IDEMPOTENT. A second run finds the value already naming $COMP_HOME/lan-cert and
# does nothing, which is what makes a forced re-run safe.
set -eu

COMP="${COMP:-edge}"
COMP_HOME="${COMP_HOME:-}"
SUDO="${SUDO:-sudo}"

say()  { echo "repoint_lan_cert: $*"; }
warn() { echo "repoint_lan_cert: $*" >&2; }

elevate() {
    if [ "$(id -u)" = 0 ]; then "$@"; else $SUDO "$@"; fi
}

# THE TREE IS ROOT-OWNED AND 0700, so every read goes through elevate too — not
# just the write. A probe that read as the invoking user would see "no config"
# on precisely the hosts this rung exists for and answer "does not apply".
CONFIG="$COMP_HOME/config"
CANONICAL="$COMP_HOME/lan-cert"

# lan_cert_value prints the configured value, or nothing. Inline `#` comments are
# stripped; the LAST assignment wins, which is what the daemon's own reader does.
lan_cert_value() {
    elevate cat "$CONFIG" 2>/dev/null | awk '
        { sub(/#.*/, "") }
        /^[ \t]*lan_cert[ \t]*=/ {
            sub(/^[ \t]*lan_cert[ \t]*=[ \t]*/, "")
            sub(/[ \t]+$/, "")
            v = $0
        }
        END { if (v != "") print v }
    '
}

# pair_present <dir> — BOTH halves are there and readable. Both, because
# repointing at a directory holding only cert.pem trades one startup abort for
# another one further in.
pair_present() {
    elevate test -r "$1/cert.pem" && elevate test -r "$1/key.pem"
}

# applies — the decision, made the same way by the probe and by the run.
#
# FAIL-SAFE DIRECTION: this rung only ever rewrites one value to name a file that
# is already on disk, so a wrong "applies" costs one no-op run — it fails OPEN,
# like the adoption it repairs after.
applies() {
    [ -n "$COMP_HOME" ] || return 1
    elevate test -f "$CONFIG" || return 1

    _cur="$(lan_cert_value)"
    [ -n "$_cur" ] || return 1                      # unset: the daemon pins no LAN cert
    case "$_cur" in /*) ;; *) return 1 ;; esac      # relative: not a value this rung wrote or understands

    # The configured directory still works — nothing is broken, leave it alone.
    # This is what keeps the rung inert on a host whose lan_cert legitimately
    # points at another name INSIDE the component dir, and it is ALSO what makes
    # an already-repointed host decline: the value then names $CANONICAL, whose
    # cert.pem is readable by definition of the repoint having happened.
    #
    # THERE IS DELIBERATELY NO SEPARATE "already naming $CANONICAL" EARLY-OUT.
    # One was written here and removed: both of its outcomes are the outcome this
    # test and pair_present below already produce, so no mutation could change
    # behaviour by deleting it — a line the suite cannot defend is a line
    # claiming to do something it does not.
    if elevate test -r "$_cur/cert.pem"; then return 1; fi

    # Broken — but only repairable if there is a pair to point AT.
    pair_present "$CANONICAL"
}

if [ "${1:-}" = "--applies" ]; then
    if applies; then exit 0; fi
    exit 1
fi

if [ "${1:-}" != "" ]; then
    warn "unknown argument '$1' (expected --applies or none)"
    exit 2
fi

CUR="$(lan_cert_value 2>/dev/null || true)"

if ! applies; then
    # SAY WHY, ALWAYS. The one state an operator must not have to infer is the
    # unrepairable one: a broken value with no pair to point at is a daemon that
    # will keep crash-looping after a ladder that reported success.
    if [ -n "$CUR" ] && [ "$CUR" != "$CANONICAL" ] && ! elevate test -r "$CUR/cert.pem" 2>/dev/null; then
        warn "lan_cert names $CUR, which holds no readable cert.pem, and $CANONICAL holds no pair to repoint to."
        warn "NOT repairing: minting a new pair would change the fingerprint every peer has pinned."
        warn "an operator can mint one deliberately with \`burrowee $COMP nginx reconcile --mode lan\`, then re-pin the peers."
    else
        say "lan_cert needs no repoint"
    fi
    exit 0
fi

say "lan_cert names $CUR, which the 0.2.0 adoption retired — repointing at $CANONICAL"

# THE REWRITE IS LINE-ORIENTED and replaces only the matched line, so comments,
# ordering and keys this rung has never heard of survive exactly as they were.
# awk with -v, never sed with the path spliced into the expression: a value
# holding a `/` or a `&` would rewrite the file into something else entirely.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT INT TERM

elevate cat "$CONFIG" | awk -v v="$CANONICAL" '
    /^[ \t]*lan_cert[ \t]*=/ { print "lan_cert=" v; next }
    { print }
' > "$TMP"

# PROVE THE REWRITE BEFORE PUBLISHING IT. An empty result — a failed read, a
# full disk — must never reach the config: the daemon cannot start without one,
# and this rung would have destroyed the only copy.
if [ ! -s "$TMP" ]; then
    warn "the rewritten config came out empty — refusing to publish it; $CONFIG is untouched"
    exit 1
fi
if ! grep -q "^lan_cert=$CANONICAL\$" "$TMP"; then
    warn "the rewritten config does not carry the repointed lan_cert — refusing to publish it; $CONFIG is untouched"
    exit 1
fi

# Same-directory scratch + rename: the config is either the old one or the new
# one, never half of either.
NEW="$CONFIG.tmp-$$"
elevate cp "$TMP" "$NEW"
elevate chmod 600 "$NEW"
elevate mv "$NEW" "$CONFIG"

say "lan_cert=$CANONICAL — the carried pair; the fingerprint peers pinned is unchanged"
