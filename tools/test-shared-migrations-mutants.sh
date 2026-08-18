#!/bin/sh
# tools/test-shared-migrations-mutants.sh — proves that
# tools/test-shared-migrations.sh can actually FAIL.
#
#     sh tools/test-shared-migrations-mutants.sh
#     dash tools/test-shared-migrations-mutants.sh
#
# A suite that has never been red is a suite nobody has any evidence about. Each
# case below breaks the shared ladder in ONE named way, and requires the suite to
# notice. Two things are asserted about every mutant before it is run, because a
# mutation that reddens for the wrong reason proves nothing:
#
#   1. THE FILE ACTUALLY CHANGED. A sed pattern that matched nothing leaves the
#      original behind, the suite passes, and the mutation is scored as
#      "survived" — the exact reading a green mutation would get.
#   2. THE MUTANT STILL PARSES (`dash -n`). A syntactically broken mutant fails
#      every test in the suite regardless of what the assertions measure, which
#      certifies nothing about them.
#
# Each mutant names the assertion it is aimed at, so a survivor points at a
# specific claim rather than at "something in the suite".
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="$HERE/tools/test-shared-migrations.sh"
SRC="$HERE/inner/_shared/migrations"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

SURVIVORS=0
RUN=0

# mutate <name> <file> <sed-expr> <what it should break>
mutate() {
    _m_name="$1"; _m_file="$2"; _m_expr="$3"; _m_claim="$4"
    RUN=$((RUN + 1))
    _m_dir="$TMP/$_m_name"
    rm -rf "$_m_dir"
    mkdir -p "$_m_dir"
    cp "$SRC"/* "$_m_dir/"
    sed -e "$_m_expr" "$SRC/$_m_file" > "$_m_dir/$_m_file"

    if cmp -s "$SRC/$_m_file" "$_m_dir/$_m_file"; then
        echo "MUTANT NOT APPLIED: $_m_name — the sed matched nothing in $_m_file." >&2
        echo "  An unapplied mutant looks exactly like a surviving one. Fix the pattern." >&2
        SURVIVORS=$((SURVIVORS + 1))
        return
    fi
    if ! dash -n "$_m_dir/$_m_file" 2>/dev/null; then
        echo "MUTANT DOES NOT PARSE: $_m_name — $_m_file is syntactically broken." >&2
        echo "  A mutant that cannot run reddens everything and certifies nothing." >&2
        SURVIVORS=$((SURVIVORS + 1))
        return
    fi

    if SHARED_MIGRATIONS_DIR="$_m_dir" sh "$SUITE" >"$TMP/$_m_name.out" 2>&1; then
        echo "SURVIVOR: $_m_name — the suite still PASSED." >&2
        echo "  claim not defended: $_m_claim" >&2
        SURVIVORS=$((SURVIVORS + 1))
    else
        echo "killed: $_m_name  ($_m_claim)"
        echo "        first failure: $(grep -m1 '^FAIL' "$TMP/$_m_name.out" | cut -c1-140)"
    fi
}

echo "== mutation run against tools/test-shared-migrations.sh =="

# --- the sweep's four guards ------------------------------------------------

mutate provably-ours-removed lib_stale_user_bins.sh \
    "s|^    if is_burrowee_binary \"\$1\"; then echo ours; else echo foreign; fi|    echo ours|" \
    "a real Go binary that is NOT ours is left in place (case 6)"

mutate operator-home-is-HOME lib_paths.sh \
    "s|^    case \"\${SUDO_USER:-}\" in|    case '' in|" \
    "the sweep resolves the OPERATOR's home via \$SUDO_USER, not \$HOME (case 11)"

mutate unit-guard-removed lib_stale_user_bins.sh \
    "s|^    if unit_naming_dir \"\$_sbp_dir\" \"\$_sbp_home\" >/dev/null 2>&1; then return 1; fi|    :|" \
    "a host whose unit still names the per-user dir is never selected (case 7)"

mutate dispatcher-always-removed lib_stale_user_bins.sh \
    "s|^    if stale_dir_has_other_burrowee_bin \"\$_rsb_dir\"; then|    if false; then|" \
    "the shared dispatcher survives while another component is installed there (case 9)"

mutate sweep-dir-equals-bindir lib_stale_user_bins.sh \
    "s|^    \[ \"\$_subd_dir\" != \"\$BIN_DIR\" \] |: |" \
    "a default cli install is never swept out from under itself (case 10)"

mutate exact-names-become-glob lib_stale_user_bins.sh \
    "s|^    for _rsb_b in \$STALE_USER_BINS; do|    for _rsb_b in \$STALE_USER_BINS burrowee-edge-notes; do|" \
    "removal is by exact name only — a name outside \$STALE_USER_BINS survives (case 8)"

# --- the runner's gate, receipts and exit contract --------------------------

# The FIRST attempt at this one was `s/if [ "$_x" -gt "$_y" ]; then return 1; fi/:/`
# and it SURVIVED — with the early return gone, 0.10.0 vs 0.2.0 still falls
# through to "equal is not older" and answers correctly. A mutation that does not
# change the answer for the case it is aimed at scores as a survivor and is
# indistinguishable from an assertion that cannot fail; the fix is a better
# mutant, not a weaker claim. This one truncates each version field to its first
# character, which is exactly what a `0.1.*` glob does to 0.10.0: it makes the
# runner read it as 0.1.0 and re-run a migration on a host that is past it.
mutate gate-is-a-glob run.sh \
    "s|^    _f=\"\${_f%%+\*}\"|    _f=\$(printf '%.1s' \"\$_f\")|" \
    "0.10.0 is NEWER than 0.2.0 — the gate is numeric, not a glob (case 3)"

mutate receipt-ignores-tree run.sh \
    "s|^    if \[ \"\$_rs_home\" = \"\$COMP_HOME\" \]; then echo \"done\"; return 0; fi|    echo \"done\"; return 0|" \
    "a receipt earned for another tree settles nothing here (cases 16, 16b)"

mutate lost-receipt-reports-2 run.sh \
    "s|^    exit 3|    exit 2|" \
    "a rung that ran but could not be recorded exits 3, not 2 (case 15)"

mutate named-version-reads-file run.sh \
    "s|^    _version=\"\$NAMED_VERSION\"|    _version=\"\$(installed_version)\"|" \
    "--installed-version REPLACES the anchor rather than merging with it (case 5b)"

mutate rerun-recorded-ignores-gate run.sh \
    "s|^        if ! version_lt \"\$_version\" \"\$_target_version\"; then|        if false; then|" \
    "the version gate is consulted at all (cases 3, 5c)"

mutate usage-error-exits-2 run.sh \
    "s|^    exit 64|    exit 2|" \
    "a wrong command line exits 64, never 2 (case 12)"

mutate empty-version-reads-as-unset run.sh \
    "s|^if \[ \"\$VERSION_NAMED\" = 1 \] && ! valid_version \"\$NAMED_VERSION\"; then|if [ -n \"\$NAMED_VERSION\" ] \&\& ! valid_version \"\$NAMED_VERSION\"; then|" \
    "an EMPTY --installed-version is refused, not read as 'not given' (case 12)"

mutate missing-script-is-skipped run.sh \
    "s|^    if \[ ! -f \"\$HERE/\$_script\" \]; then|    if false; then|" \
    "a ledger row whose script is missing fails the run (case 14)"

mutate absent-tree-ignores-flag run.sh \
    "s|^    if \[ \"\$VERSION_NAMED\" = 1 \]; then$|    if false; then|" \
    "an absent tree the operator asserted a version FOR is a refusal (case 13)"

mutate empty-ledger-is-a-noop run.sh \
    "s|^if \[ \"\$_rows\" = 0 \]; then|if false; then|" \
    "a ledger with no rows fails rather than reporting a clean no-op (case 14c)"

mutate nonnumeric-target-accepted run.sh \
    "s|^    if ! valid_version \"\$_target_version\"; then|    if false; then|" \
    "a ledger row with a non-numeric target fails rather than becoming 0.0.0 (case 14d)"

mutate receipt-mode-widened run.sh \
    "s|as_owner chmod 0700 \"\$RECEIPTS\"|as_owner chmod 0755 \"\$RECEIPTS\"|" \
    "the receipts directory is 0700 (case 1)"

echo "== $RUN mutants, $SURVIVORS survived =="
[ "$SURVIVORS" = 0 ] || exit 1
