#!/bin/sh
# tools/test-modules.sh — the module gates.
#
# (1) LOCK      — every module's recorded sha256 matches its bytes, and every
#                 module on disk is listed. An edit without a version bump is
#                 what makes "which copy is newer" unanswerable across products.
# (2) DEPS      — every `# needs:` dependency is included EARLIER in each
#                 generated bootstrap that includes the dependent module. An
#                 undeclared order bug surfaces on an operator's machine as
#                 "command not found", after the download and before the gate.
# (3) GENERATOR — regenerating leaves every committed bootstrap byte-identical.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODDIR="$ROOT/tools/modules"
LOCK="$MODDIR/MODULES.lock"
die() { printf '\n✗ FAILED: %s\n' "$*" >&2; exit 1; }

sha_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else die "neither shasum nor sha256sum found"; fi
}

printf '\n=== LOCK: modules match MODULES.lock ===\n'
[ -f "$LOCK" ] || die "missing $LOCK"
while read -r name version want; do
    [ -n "${name:-}" ] || continue
    case "$name" in \#*) continue ;; esac
    f="$MODDIR/$name.sh"
    [ -f "$f" ] || die "$LOCK lists '$name' but $f does not exist"
    got="$(sha_of "$f")"
    [ "$got" = "$want" ] \
        || die "$name changed without a version bump (lock says $version/$want, file is $got)
    bump the '# module:' header and re-run tools/lock-modules.sh"
    hdr="$(sed -n '1,4s/^# module:[[:space:]]*\([a-z0-9-]*\)[[:space:]]*v\([0-9][0-9]*\).*/\1 v\2/p' "$f")"
    [ "$hdr" = "$name $version" ] \
        || die "$f header says '$hdr', $LOCK says '$name $version'"
done < "$LOCK"
for f in "$MODDIR"/*.sh; do
    n="$(basename "$f" .sh)"
    grep -q "^$n " "$LOCK" || die "$f is not listed in $LOCK"
done
printf '  OK\n'

printf '\n=== DEPS: every "# needs:" is included earlier ===\n'
for gen in "$ROOT"/*/install.sh "$ROOT"/*/upgrade.sh "$ROOT"/*/updater.install.sh; do
    [ -f "$gen" ] || continue
    order="$(sed -n 's/^# BEGIN \([a-z0-9-]*\)$/\1/p' "$gen")"
    for mod in $order; do
        needs="$(sed -n '1,6s/^# needs:[[:space:]]*//p' "$MODDIR/$mod.sh" 2>/dev/null || true)"
        for dep in $needs; do
            seen=0
            for m in $order; do
                [ "$m" = "$dep" ] && seen=1
                [ "$m" = "$mod" ] && break
            done
            [ "$seen" = 1 ] || die "$gen includes '$mod' which needs '$dep', but '$dep' is not included before it"
        done
    done
done
printf '  OK\n'

printf '\n=== GENERATOR: committed bootstraps are what the generator writes ===\n'
sh "$ROOT/tools/gen-bootstraps.sh" >/dev/null 2>&1 || die "gen-bootstraps.sh failed"
dirty="$(cd "$ROOT" && git status --porcelain -- '*/install.sh' '*/upgrade.sh' '*/updater.install.sh' '*/preflight.sh')"
[ -z "$dirty" ] || die "regenerating changed committed bootstraps — they are stale, commit the regeneration:
$dirty"
printf '  OK\n'

printf '\nALL OK — modules locked, dependencies ordered, bootstraps current\n'
