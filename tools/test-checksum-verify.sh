#!/bin/sh
# tools/test-checksum-verify.sh — the outer bootstrap's checksum gate must work
# on hashers that predate `--ignore-missing`.
#
# The gate used to run `shasum -a 256 -c --ignore-missing SHA256SUMS.txt`. That
# option is a 2016-era addition (Digest::SHA 5.96 / coreutils 8.25): the stock
# shasum on an older macOS answers "Unknown option: ignore-missing" and exits
# non-zero, which the `||` reported as "checksum mismatch". Every install on
# such a host therefore accused an intact, correctly signed zip of tampering
# (seen 2026-08-25, gateway install on a 2012 Mac mini).
#
#     sh tools/test-checksum-verify.sh          # this shell
#     dash tools/test-checksum-verify.sh        # and this one, always
#
# (1) STATIC   — no bootstrap, template or generated, may name --ignore-missing.
# (2) BEHAVIOR — the shipped block, extracted verbatim from cli/install.sh, is
#     driven against a stub `shasum` that models the old one: good zip verifies,
#     tampered zip aborts, absent entry aborts, and a name that merely CONTAINS
#     the wanted one is not mistaken for it.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ FAILED: %s\n' "$*" >&2; exit 1; }

# ---- (1) STATIC: the option must not come back ------------------------------
say "STATIC: no --ignore-missing in any bootstrap"
# Code lines only: the block carries a comment naming the option it dropped.
found="$(grep -lE '^[^#]*--ignore-missing' \
    "$REPO_ROOT"/tools/bootstrap.template.sh \
    "$REPO_ROOT"/tools/relay-bootstrap.template.sh \
    "$REPO_ROOT"/*/install.sh \
    "$REPO_ROOT"/*/upgrade.sh \
    "$REPO_ROOT"/*/updater.install.sh 2>/dev/null || true)"
[ -z "$found" ] \
    || die "these still verify with --ignore-missing (breaks pre-2016 hashers):
$found"
printf '  OK: no --ignore-missing\n'

# ---- (2) extract the shipped block ------------------------------------------
# Out of the GENERATED cli/install.sh, so the test drives the bytes that ship.
say "BEHAVIOR: extracting the checksum-verify block from cli/install.sh"
sed -n '/^# BEGIN verify-checksum/,/^# END verify-checksum/p' \
    "$REPO_ROOT/cli/install.sh" > "$W/verify.sh"
grep -q '^# END verify-checksum' "$W/verify.sh" \
    || die "could not extract the checksum-verify block from cli/install.sh (markers missing or renamed)"
sed -n '/^sha256_of()/,/^}/p' "$REPO_ROOT/cli/install.sh" > "$W/sha256_of.sh"
grep -q '^sha256_of()' "$W/sha256_of.sh" \
    || die "could not extract sha256_of() from cli/install.sh"

# relay ships its own, separately-coded inline gate (own shasum/sha256sum
# probe, $ZIP_FILE rather than $ZIP, no sha256_of) — extract it too, out of
# the GENERATED relay/install.sh, so both shipped variants of the portable
# checksum gate are driven by this test, not just cli's.
say "BEHAVIOR: extracting the verify-checksum-inline block from relay/install.sh"
sed -n '/^# BEGIN verify-checksum-inline/,/^# END verify-checksum-inline/p' \
    "$REPO_ROOT/relay/install.sh" > "$W/verify_relay.sh"
grep -q '^# END verify-checksum-inline' "$W/verify_relay.sh" \
    || die "could not extract the verify-checksum-inline block from relay/install.sh (markers missing or renamed)"

# ---- stub hashers -----------------------------------------------------------
# `shasum` as an old Digest::SHA ships it: -a 256 <file> works, --ignore-missing
# does not exist. Anything the block relies on beyond that is a portability bug.
mkdir -p "$W/bin"
cat > "$W/bin/shasum" <<'STUB'
#!/bin/sh
for a in "$@"; do
    case "$a" in
        --ignore-missing)
            echo "Unknown option: ignore-missing" >&2
            echo "Type shasum -h for help" >&2
            exit 1 ;;
    esac
done
exec /usr/bin/shasum "$@"
STUB
chmod +x "$W/bin/shasum"
[ -x /usr/bin/shasum ] || die "no /usr/bin/shasum to back the stub"

# The stub must actually model the old tool, or every case below passes vacuously.
if PATH="$W/bin:$PATH" shasum -a 256 -c --ignore-missing /dev/null >/dev/null 2>&1; then
    die "the stub accepted --ignore-missing — it does not model a pre-2016 shasum"
fi
printf '  OK: stub shasum rejects --ignore-missing, as the old one does\n'

# ---- driver -----------------------------------------------------------------
# Sources the two extracted blocks in a child shell so `fail` can exit without
# killing this script. $TMP and $ZIP are the block's inputs.
cat > "$W/run.sh" <<'RUNNER'
#!/bin/sh
set -eu
info() { :; }
ok()   { printf 'OK: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
. "$BLOCK_DIR/sha256_of.sh"
TMP="$FIXTURE"
ZIP="$WANT_ZIP"
. "$BLOCK_DIR/verify.sh"
ok "checksum verified"
RUNNER

# fixture: the wanted zip, a decoy whose NAME CONTAINS the wanted one, and a
# third entry for a file that was never downloaded (the case --ignore-missing
# was there to tolerate).
F="$W/fixture"
mkdir -p "$F"
printf 'the real payload\n'  > "$F/burrowee-cli-darwin-amd64.zip"
printf 'not the payload\n'   > "$F/x-burrowee-cli-darwin-amd64.zip"
{
    /usr/bin/shasum -a 256 "$F/x-burrowee-cli-darwin-amd64.zip" | sed 's| .*/| |'
    /usr/bin/shasum -a 256 "$F/burrowee-cli-darwin-amd64.zip"   | sed 's| .*/| |'
    echo "0000000000000000000000000000000000000000000000000000000000000000  burrowee-cli-linux-arm64.zip"
} > "$F/SHA256SUMS.txt"

run() {  # run <fixture-dir> <zip>
    FIXTURE="$1" WANT_ZIP="$2" BLOCK_DIR="$W" PATH="$W/bin:$PATH" \
        sh "$W/run.sh" 2>&1
}

# relay's driver: no sha256_of, and the block reads $ZIP_FILE rather than $ZIP.
cat > "$W/run_relay.sh" <<'RUNNER'
#!/bin/sh
set -eu
info() { :; }
ok()   { printf 'OK: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TMP="$FIXTURE"
ZIP_FILE="$WANT_ZIP"
. "$BLOCK_DIR/verify_relay.sh"
ok "checksum verified"
RUNNER

run_relay() {  # run_relay <fixture-dir> <zip>
    FIXTURE="$1" WANT_ZIP="$2" BLOCK_DIR="$W" PATH="$W/bin:$PATH" \
        sh "$W/run_relay.sh" 2>&1
}

say "CASE: intact zip, old shasum"
out="$(run "$F" burrowee-cli-darwin-amd64.zip)" \
    || die "intact zip rejected on a pre-2016 shasum — the bug is back:
$out"
case "$out" in *"checksum verified"*) ;; *) die "no 'checksum verified' in: $out" ;; esac
printf '  OK: verified\n'

say "CASE: binary-format sums line (hash *name)"
B="$W/binfmt"; mkdir -p "$B"
cp "$F/burrowee-cli-darwin-amd64.zip" "$B/"
/usr/bin/shasum -a 256 "$B/burrowee-cli-darwin-amd64.zip" \
    | sed 's|  .*/|  *|' > "$B/SHA256SUMS.txt"
grep -q ' \*burrowee-cli-darwin-amd64.zip$' "$B/SHA256SUMS.txt" \
    || die "fixture is not in binary format: $(cat "$B/SHA256SUMS.txt")"
out="$(run "$B" burrowee-cli-darwin-amd64.zip)" \
    || die "binary-format entry not matched: $out"
printf '  OK: verified\n'

say "CASE: tampered zip aborts"
T="$W/tampered"; mkdir -p "$T"
cp "$F/SHA256SUMS.txt" "$T/"
printf 'the real payloadX\n' > "$T/burrowee-cli-darwin-amd64.zip"
if out="$(run "$T" burrowee-cli-darwin-amd64.zip)"; then
    die "tampered zip was ACCEPTED: $out"
fi
case "$out" in *"checksum mismatch"*) ;; *) die "wrong refusal for a tampered zip: $out" ;; esac
printf '  OK: aborted with "checksum mismatch"\n'

say "CASE: no entry for the downloaded zip aborts"
if out="$(run "$F" burrowee-cli-windows-amd64.zip)"; then
    die "a zip with no sums entry was ACCEPTED: $out"
fi
case "$out" in *"no checksum entry"*) ;; *) die "wrong refusal for a missing entry: $out" ;; esac
printf '  OK: aborted with "no checksum entry"\n'

say "CASE: a longer name containing the wanted one is not a match"
# Only the decoy is listed; the wanted zip must NOT borrow its entry.
D="$W/decoy"; mkdir -p "$D"
cp "$F/burrowee-cli-darwin-amd64.zip" "$D/"
/usr/bin/shasum -a 256 "$F/x-burrowee-cli-darwin-amd64.zip" | sed 's| .*/| |' > "$D/SHA256SUMS.txt"
if out="$(run "$D" burrowee-cli-darwin-amd64.zip)"; then
    die "matched a DIFFERENT file's entry by substring: $out"
fi
case "$out" in *"no checksum entry"*) ;; *) die "wrong refusal for a substring-only name: $out" ;; esac
printf '  OK: aborted with "no checksum entry"\n'

# ---- same cases again, against relay's separately-coded inline block -------
# Same fixtures (F/B/T/D built above), same stub shasum — only the driver
# differs (run_relay instead of run).

say "CASE (relay): intact zip, old shasum"
out="$(run_relay "$F" burrowee-cli-darwin-amd64.zip)" \
    || die "relay: intact zip rejected on a pre-2016 shasum — the bug is back:
$out"
case "$out" in *"checksum verified"*) ;; *) die "relay: no 'checksum verified' in: $out" ;; esac
printf '  OK: verified\n'

say "CASE (relay): binary-format sums line (hash *name)"
out="$(run_relay "$B" burrowee-cli-darwin-amd64.zip)" \
    || die "relay: binary-format entry not matched: $out"
case "$out" in *"checksum verified"*) ;; *) die "relay: no 'checksum verified' in: $out" ;; esac
printf '  OK: verified\n'

say "CASE (relay): tampered zip aborts"
if out="$(run_relay "$T" burrowee-cli-darwin-amd64.zip)"; then
    die "relay: tampered zip was ACCEPTED: $out"
fi
case "$out" in *"checksum mismatch"*) ;; *) die "relay: wrong refusal for a tampered zip: $out" ;; esac
printf '  OK: aborted with "checksum mismatch"\n'

say "CASE (relay): no entry for the downloaded zip aborts"
if out="$(run_relay "$F" burrowee-cli-windows-amd64.zip)"; then
    die "relay: a zip with no sums entry was ACCEPTED: $out"
fi
case "$out" in *"no checksum entry"*) ;; *) die "relay: wrong refusal for a missing entry: $out" ;; esac
printf '  OK: aborted with "no checksum entry"\n'

say "CASE (relay): a longer name containing the wanted one is not a match"
if out="$(run_relay "$D" burrowee-cli-darwin-amd64.zip)"; then
    die "relay: matched a DIFFERENT file's entry by substring: $out"
fi
case "$out" in *"no checksum entry"*) ;; *) die "relay: wrong refusal for a substring-only name: $out" ;; esac
printf '  OK: aborted with "no checksum entry"\n'

printf '\nALL OK — the checksum gate works on hashers without --ignore-missing\n'
