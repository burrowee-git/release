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

# The generator's OWN generated locations, anchored explicitly — NOT a git
# pathspec glob. '*/install.sh' etc. also match the hand-written
# inner/{agent,cli,edge,gateway}/install.sh, inner/{edge,gateway}/updater.install.sh
# and inner/_shared/migrations/upgrade.sh: a glob crosses '/' in a git pathspec,
# so any later task touching an inner installer would get a false "stale,
# commit the regeneration" naming a file the generator never writes. Shared by
# the DEPS loop (which must also see preflight.sh — a module spliced into the
# preflight template needs the same ordering check as one in the bootstrap
# template) and the GENERATOR diff below.
GENERATED_REL="cli/preflight.sh cli/install.sh cli/upgrade.sh \
gateway/preflight.sh gateway/install.sh gateway/upgrade.sh gateway/updater.install.sh \
edge/preflight.sh edge/install.sh edge/upgrade.sh edge/updater.install.sh \
agent/preflight.sh agent/install.sh agent/upgrade.sh \
relay/install.sh"

printf '\n=== DEPS: every "# needs:" is included earlier ===\n'
for relgen in $GENERATED_REL; do
    gen="$ROOT/$relgen"
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

printf '\n=== GENERATOR-FAILS-CLOSED: a missing module aborts before any destination file is written ===\n'
# Regression cover for the bug where expand_includes ran on the LEFT of a
# pipeline: `set -eu` cannot see a pipeline's left-hand exit status, so a
# missing module made awk print to stderr and exit 1 while the pipeline's sed
# stage still ran to completion on the truncated input, wrote a decapitated
# bootstrap, and gen-bootstraps.sh exited 0. Proven here against a throwaway
# scratch tree (never the real repo) so it fires on every run, not just once.
SCRATCH="$(mktemp -d)"
mkdir -p "$SCRATCH/tools"
cp "$ROOT/tools/gen-bootstraps.sh" "$SCRATCH/tools/gen-bootstraps.sh"
cp "$ROOT/tools/preflight.template.sh" "$SCRATCH/tools/preflight.template.sh"
cp "$ROOT/tools/relay-bootstrap.template.sh" "$SCRATCH/tools/relay-bootstrap.template.sh"
{
    echo '#!/bin/sh'
    echo '@INCLUDE:does-not-exist@'
    echo 'echo hi'
} > "$SCRATCH/tools/bootstrap.template.sh"
scratch_log="$SCRATCH/gen.log"
if BURROWEE_PUBKEY_FILE="$ROOT/tools/testkeys/test.pub" BURROWEE_MIN_VERSION=0.0.1 \
   sh "$SCRATCH/tools/gen-bootstraps.sh" >"$scratch_log" 2>&1
then
    rm -rf "$SCRATCH"
    die "gen-bootstraps.sh exited 0 against a template that @INCLUDEs a nonexistent module — it must fail closed"
fi
if [ -e "$SCRATCH/cli/install.sh" ]; then
    rm -rf "$SCRATCH"
    die "a missing module still left a file at cli/install.sh — expand_includes' failure did not stop the write (see $scratch_log)"
fi
rm -rf "$SCRATCH"
printf '  OK\n'

printf '\n=== GENERATOR: committed bootstraps are what the generator writes ===\n'
gen_log="$(sh "$ROOT/tools/gen-bootstraps.sh" 2>&1)" || die "gen-bootstraps.sh failed:
$gen_log"
dirty="$(cd "$ROOT" && git status --porcelain -- $GENERATED_REL)"
[ -z "$dirty" ] || die "regenerating changed committed bootstraps — they are stale, commit the regeneration:
$dirty"
printf '  OK\n'

printf '\nALL OK — modules locked, dependencies ordered, bootstraps current\n'
