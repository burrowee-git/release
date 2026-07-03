#!/bin/sh
# gen-bootstraps.sh — generate the four self-contained outer bootstraps
# (cli/install.sh, gateway/install.sh, edge/install.sh, relay/install.sh)
# from their respective templates, plus the per-component OS-dependency
# preflight (cli/preflight.sh, gateway/preflight.sh, edge/preflight.sh).
#
# cli/gateway/edge use tools/bootstrap.template.sh (public GitHub-release
# channel) + tools/preflight.template.sh (OS-dep installer). relay uses
# tools/relay-bootstrap.template.sh (private gated channel: challenge-response
# ed25519 signing + gated downloads) and has no preflight.
#
# Each generated file is byte-identical within its template family except for
# the @COMP@ and @PUBKEY@ substitutions. The outer bootstrap is THE TRUST
# ANCHOR, so the baked @PUBKEY@ must be the real release signing pubkey before
# activation. The outer bootstrap also pins its preflight's sha256
# (@PREFLIGHT_SHA256@) — preflight runs before minisign exists, so the pin is
# its integrity anchor; ORDER: render preflight first, then bake its hash in.
#
# Pubkey resolution (first that exists wins):
#   1. $BURROWEE_PUBKEY_FILE   (explicit override; used by the offline E2E test)
#   2. burrowee-release.pub    (the REAL release signing pubkey — Phase 7/A2)
#   3. tools/testkeys/test.pub (the local TEST key — Phase 5a)
#   4. none -> a clearly-marked TEMP placeholder is baked in, and the generated
#      bootstraps WILL refuse to run (the runtime guards on *TEMP*). Regenerate
#      once a real key exists.
#
# The @PUBKEY@ value is the base64 key line of a minisign .pub file (the last
# non-comment line) — exactly what `minisign -V -P <pubkey>` expects inline.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEMPLATE="$ROOT/tools/bootstrap.template.sh"
RELAY_TEMPLATE="$ROOT/tools/relay-bootstrap.template.sh"
PREFLIGHT_TEMPLATE="$ROOT/tools/preflight.template.sh"
[ -f "$TEMPLATE" ] || { echo "✗ missing template: $TEMPLATE" >&2; exit 1; }
[ -f "$RELAY_TEMPLATE" ] || { echo "✗ missing relay template: $RELAY_TEMPLATE" >&2; exit 1; }
[ -f "$PREFLIGHT_TEMPLATE" ] || { echo "✗ missing preflight template: $PREFLIGHT_TEMPLATE" >&2; exit 1; }

# sha256 of a file (shasum on mac, sha256sum on linux) — for the preflight pin.
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else echo "✗ neither shasum nor sha256sum found — cannot compute preflight pin" >&2; exit 1; fi
}

# ---- resolve the pubkey -------------------------------------------------
pubfile=""
for cand in "${BURROWEE_PUBKEY_FILE:-}" "$ROOT/burrowee-release.pub" "$ROOT/tools/testkeys/test.pub"; do
    [ -n "$cand" ] || continue
    if [ -f "$cand" ]; then pubfile="$cand"; break; fi
done

if [ -n "$pubfile" ]; then
    # last non-empty, non-comment line = the base64 key line
    PUBKEY="$(grep -v '^untrusted comment:' "$pubfile" | grep -v '^[[:space:]]*$' | tail -n1)"
    [ -n "$PUBKEY" ] || { echo "✗ could not extract a pubkey line from $pubfile" >&2; exit 1; }
    echo "→ baking pubkey from: $pubfile"
else
    # No key file anywhere yet. Bake a TEMP placeholder — the runtime guard in
    # the template aborts on *TEMP* so these can never silently install.
    PUBKEY="RWTEMP_PLACEHOLDER_REGENERATE_AFTER_PHASE5A_OR_A2_xxxxxxxxxxxx"
    echo "! no pubkey file found (burrowee-release.pub / tools/testkeys/test.pub)" >&2
    echo "! baking a TEMP placeholder — generated bootstraps will REFUSE to run." >&2
    echo "! create the key (Phase 5a: minisign -G ... or Phase A2) and re-run." >&2
fi

# ---- generate cli/gateway/edge (public GitHub-release channel) ----------
# ORDER per comp: render <comp>/preflight.sh FIRST (so we can sha256 it), then
# render <comp>/install.sh baking that hash as @PREFLIGHT_SHA256@. @NGINX@ is 1
# for edge (installs nginx + stream module), 0 for cli/gateway.
for comp in cli gateway edge; do
    mkdir -p "$ROOT/$comp"
    case "$comp" in
        edge) nginx=1 ;;
        *)    nginx=0 ;;
    esac

    # (1) preflight — tmp-then-mv atomic write.
    pf_out="$ROOT/$comp/preflight.sh"
    pf_tmp="$pf_out.tmp.$$"
    sed -e "s|@COMP@|$comp|g" -e "s|@NGINX@|$nginx|g" "$PREFLIGHT_TEMPLATE" > "$pf_tmp"
    chmod +x "$pf_tmp"
    mv -f "$pf_tmp" "$pf_out"
    pf_sha="$(sha256_of "$pf_out")"
    echo "✓ wrote $pf_out  (sha256 $pf_sha)"

    # (2) install.sh — bake @COMP@, @PUBKEY@, and the preflight's @PREFLIGHT_SHA256@.
    # None of these values contains another's placeholder. tmp-then-mv atomic.
    out="$ROOT/$comp/install.sh"
    tmp="$out.tmp.$$"
    sed -e "s|@COMP@|$comp|g" -e "s|@PUBKEY@|$PUBKEY|g" -e "s|@PREFLIGHT_SHA256@|$pf_sha|g" "$TEMPLATE" > "$tmp"
    chmod +x "$tmp"
    mv -f "$tmp" "$out"
    echo "✓ wrote $out"
done

# ---- generate relay (private gated channel) -----------------------------
# Uses the relay-specific template — distinct from the public template above.
# Same @PUBKEY@ trust anchor (minisign integrity layer); @COMP@=relay.
comp=relay
out="$ROOT/$comp/install.sh"
mkdir -p "$ROOT/$comp"
tmp="$out.tmp.$$"
sed -e "s|@COMP@|$comp|g" -e "s|@PUBKEY@|$PUBKEY|g" "$RELAY_TEMPLATE" > "$tmp"
chmod +x "$tmp"
mv -f "$tmp" "$out"
echo "✓ wrote $out  (relay gated-channel bootstrap)"
