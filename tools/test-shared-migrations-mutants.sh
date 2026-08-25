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
    # THE sed ITSELF MUST SUCCEED. A bad expression — most often a delimiter that
    # also appears in the pattern — exits non-zero and leaves an EMPTY file
    # behind, and an empty rung reddens every case that touches it. Three
    # mutants were scored "killed" that way before this check existed, which is
    # the same defect as a surviving one: a red suite that is red for a reason
    # nobody claimed.
    if ! sed -e "$_m_expr" "$SRC/$_m_file" > "$_m_dir/$_m_file" 2>"$TMP/$_m_name.sed"; then
        echo "MUTANT EXPRESSION IS BROKEN: $_m_name — sed refused it:" >&2
        sed -n '1,3p' "$TMP/$_m_name.sed" >&2
        echo "  The file it left behind is empty, which reddens everything and proves nothing." >&2
        SURVIVORS=$((SURVIVORS + 1))
        return
    fi

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
    "s|^    if _sbd_u=\"\$(unit_naming_bin \"\$1\" \"\$2\" \"\$3\")\"; then|    if false; then|" \
    "a file some unit still names is left in place (case 7)"

# The guard used to be asked about the DIRECTORY. Feeding it an empty basename
# restores that question, and case 7 is what notices: on admin-kr one edge unit
# naming the per-user directory blocked six gateway names it does not mention.
mutate unit-guard-scoped-to-the-directory lib_stale_user_bins.sh \
    "s|^    if _sbd_u=\"\$(unit_naming_bin \"\$1\" \"\$2\" \"\$3\")\"; then|    if _sbd_u=\"\$(unit_naming_bin \"\$1\" \"\" \"\$3\")\"; then|" \
    "the unit guard is asked PER FILE, not per directory (case 7)"

# The substring collision: with the terminator test gone, any occurrence counts,
# so a unit naming burrowee-edge-updater spares burrowee-edge.
# @-DELIMITED, and it has to be: this expression contains `||`, which with `|` as
# the delimiter made sed refuse it outright. It then wrote an EMPTY file, the
# suite reddened on every case that touches the sweep, and the mutant was scored
# "killed" — a false kill that stood until the harness started checking sed's own
# exit status.
mutate basename-match-not-terminated lib_stale_user_bins.sh \
    "s@^        \[ -n \"\$_lnb_l\" \] .. return 0@        return 0@" \
    "the basename match TERMINATES — burrowee-edge-updater's unit does not protect burrowee-edge (case 7b)"

mutate root-twin-ignored lib_stale_user_bins.sh \
    "s|^    if ! system_twin_exists \"\$2\"; then|    if false; then|" \
    "a per-user binary with no root-installed twin is the LIVE install and survives (cases 9b, 18, 18c)"

mutate foreign-file-counts-as-a-root-install lib_stale_user_bins.sh \
    "s|^    \[ \"\$(stale_bin_verdict \"\$BIN_DIR/\$1\")\" = ours \]|    [ -e \"\$BIN_DIR/\$1\" ]|" \
    "an operator's own file in \$BIN_DIR is not evidence of a root install (case 9d)"

mutate sweep-dir-equals-bindir lib_stale_user_bins.sh \
    "s|^    \[ \"\$_subd_dir\" != \"\$BIN_DIR\" \] |: |" \
    "a default cli install is never swept out from under itself (case 10)"

mutate exact-names-become-glob lib_stale_user_bins.sh \
    "s|^    for _rsb_b in \$STALE_USER_BINS; do|    for _rsb_b in \$STALE_USER_BINS burrowee-edge-notes; do|" \
    "removal is by exact name only — a name outside \$STALE_USER_BINS survives (case 8)"

# --- the post-removal shell hint -------------------------------------------
#
# $SHELL is the mutant that matters here. Under sudo it names the shell of the
# environment that INVOKED sudo, not the account whose running shell holds the
# stale path, and the two are routinely different — so this mutation is not a
# hypothetical simplification, it is the implementation anyone would write first.
# It is only killable because the fixtures set the two variables to DIFFERENT
# shells.

mutate hint-reads-SHELL lib_stale_user_bins.sh \
    "s@^    \*) _sbsh_shell=.*@    *) _sbsh_shell=\"\${SHELL:-}\" ;;@" \
    "the hint names \$SUDO_USER's LOGIN SHELL, never \$SHELL (cases 20a, 20b)"

# Field 6 is the home directory and field 7 is the shell. An off-by-one here
# yields a plausible-looking absolute path, so the hint still prints — it just
# names a directory instead of a shell and silently falls to the generic branch.
mutate hint-reads-passwd-field-6 lib_stale_user_bins.sh \
    "s@cut -d: -f7@cut -d: -f6@" \
    "the login shell is field 7 of the passwd entry (case 20a)"

mutate hint-printed-unconditionally lib_stale_user_bins.sh \
    "s@^    if \[ \"\${STALE_BINS_REMOVED:-0}\" -gt 0 \]; then@    if true; then@" \
    "a sweep that removed NOTHING prints no shell hint at all (case 20c)"

# With fish out of the case list it falls through to the generic branch and is
# handed `hash -r` — which fish answers with "Unknown command: hash", exit 127.
mutate fish-told-to-run-hash-r lib_stale_user_bins.sh \
    "s@^    fish)@    fish-is-never-matched)@" \
    "fish is never handed \`hash -r\`, which is not a fish command (case 20b)"

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

mutate deferred-rung-reports-1 run.sh \
    "s|^    if \[ \"\$_rm_rc\" = 3 \]; then|    if false; then|" \
    "a rung that DEFERRED exits 3 (still pending), not 1 (failed) (case 15b)"

mutate deferred-rung-does-not-stop-the-walk run.sh \
    "s|^        break\$|        :|" \
    "nothing above a deferred rung runs (case 15b)"

mutate named-version-reads-file run.sh \
    "s|^    _version=\"\$NAMED_VERSION\"|    _version=\"\$(installed_version)\"|" \
    "--installed-version REPLACES the anchor rather than merging with it (case 5b)"

mutate rerun-recorded-ignores-gate run.sh \
    "s|^        if ! version_lt \"\$_version\" \"\$_target_version\"; then|        if false; then|" \
    "the version gate is consulted at all (cases 3, 5c)"

# THE FLOOR GATE'S INCLUSIVITY, inverted in place: "skip when target < floor"
# becomes "skip unless floor < target", which skips the rung targeting the floor
# line itself — the strict comparison --assume-below exists to NOT be. Every
# single-rung floor run in the suite then reports "nothing applied", which is
# exactly the silent no-op upgrade.sh's operator was stuck in.
mutate floor-gate-exclusive run.sh \
    "s|^        if version_lt \"\$_target_version\" \"\$FLOOR_VERSION\"; then|        if ! version_lt \"\$FLOOR_VERSION\" \"\$_target_version\"; then|" \
    "the floor is INCLUSIVE — a rung targeting the floor line itself runs (case 33)"

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

# THE RECEIPT KEY, reverted to the file-only name it used to be. One global
# substitution turns `<script>@<target>.done` back into `<script>.done` in
# receipt_state and record_migration alike — the exact scheme under which the
# run that satisfied a 0.2.0 row silently satisfies the 0.3.0 row that re-lists
# the same file, because the receipt check runs BEFORE the version gate.
mutate receipt-keyed-by-file-only run.sh \
    "s|\$1@\$2\.done|\$1.done|g" \
    "the receipt is PER ITEM — a file re-listed at a newer target is a new item, not already done (case 34b)"

# --- upgrade.sh, the override ----------------------------------------------

mutate upgrade-does-not-force upgrade.sh \
    "s|^sh \"\$RUNNER\" --assume-below \"\$WANT_NORM\" --rerun-recorded|sh \"\$RUNNER\"|" \
    "upgrade.sh forces a rung the plain ladder skips on a same-semver host (case 17b)"

mutate upgrade-crosscheck-decorative upgrade.sh \
    "s|^if line_lt \"\$KIT_NORM\" \"\$WANT_NORM\"; then|if false; then|" \
    "a floor ABOVE the kit's ladder top is REFUSED (case 17d)"

# The cross-check's OTHER direction, restored to the equality test it replaced.
# `!=` refuses everything but the exact top — which is precisely the shape that
# breaks the forcing path on the first release whose line moved past a ladder
# that shipped no new rung. Only the backfill case can tell `line_lt` from `!=`:
# the top itself passes both.
mutate upgrade-refuses-the-backfill upgrade.sh \
    "s|^if line_lt \"\$KIT_NORM\" \"\$WANT_NORM\"; then|if [ \"\$WANT_NORM\" != \"\$KIT_NORM\" ]; then|" \
    "a floor BELOW the kit's top is the normal backfill, never a refusal (case 17h)"

# The floor degraded back to "everything since 0.0.0" — the invocation this
# script used to make. On a single-rung ladder the two are indistinguishable;
# the two-target ladder is what notices, because 0.0.0 reopens the rung BELOW
# the floor that the operator was promised is treated as genuinely done.
mutate upgrade-floor-becomes-zero upgrade.sh \
    "s|^sh \"\$RUNNER\" --assume-below \"\$WANT_NORM\" --rerun-recorded|sh \"\$RUNNER\" --installed-version 0.0.0 --rerun-recorded|" \
    "upgrade.sh hands the runner the FLOOR, not 'everything since 0.0.0' (case 31a)"

mutate upgrade-swallows-the-code upgrade.sh \
    "s|^exit \"\$CODE\"|exit 0|" \
    "the ladder's exit code is propagated, not swallowed (cases 17b, 17f)"

mutate upgrade-does-not-list-the-rungs upgrade.sh \
    "s|^ROWS=.*|ROWS=\"\"|" \
    "the rungs about to be re-run are NAMED before any of them runs (case 17b)"

# --- the adoption rung, its stop, and the runner's contract around it -------
#
# Every mutant here is a plausible simplification of the rung rather than an
# invented defect: each one is a thing somebody would write, and each is silent
# in the direction that looks like success.

# THE MOVING TARGET. Without the stop the copy runs while burrowee-edge is up,
# and the daemon mints identity/relay_ed.key and bridge/bridge_ed.key into the
# destination — which the copy then never overwrites, so the MINTED keys win and
# the host comes up with an identity the console has never seen.
mutate stop-dropped adopt_user_tree.sh \
    "s|^if ! stop_component; then exit 1; fi|:|" \
    "the rung REFUSES rather than copying under a daemon it could not stop (case 24)"

# The other half of the same claim: asking is not stopping. A supervisor that
# logs and does nothing is what a container, or an unloaded unit, looks like.
# The FIRST attempt at this one replaced the WAIT loop with `while false`, and it
# SURVIVED: skipping the wait leaves the post-condition below intact, so a daemon
# that was never going to stop is still caught. A mutation that does not change
# the answer for the case it is aimed at is indistinguishable from an assertion
# that cannot fail, and the fix is a better mutant rather than a weaker claim.
# This one deletes the post-condition itself, which is the actual simplification
# somebody would write: the supervisor said 0, so it must be down.
mutate stop-is-a-request-not-a-postcondition adopt_user_tree.sh \
    "s@^    if comp_alive; then@    if false; then@" \
    "the stop is verified against the running.json pid, not assumed from the supervisor's exit code (case 24)"

# THE BLINDNESS ASYMMETRY, both directions. Getting either backwards silently
# skips the migration on exactly the hosts it exists for.
mutate blind-probe-answers-already-done adopt_user_tree.sh \
    "s|^    elevate test -s \"\$DST/\$ID_REL\" >/dev/null 2>\&1|    return 0|" \
    "an unreadable DESTINATION answers 'still needed', never 'already done' (case 23a)"

mutate blind-source-answers-nothing-to-adopt adopt_user_tree.sh \
    "s@^    \[ \"\$SRC_BLIND\" = 1 \] .. return 1@    :@" \
    "an unreadable SOURCE answers 'still needed', never 'nothing to adopt' (cases 23c, 28e)"

# With the destination check gone the rung would re-run forever on every adopted
# host — the per-user tree survives the copy, so the source-side evidence alone
# never stops saying yes. That is the dishonesty the gateway's probe had.
mutate probe-ignores-the-destination adopt_user_tree.sh \
    "s|^    if already_adopted; then exit 1; fi|    if false; then exit 1; fi|" \
    "a destination that already holds an identity ends the rung's evaluation (case 23b)"

# PRE-FLIGHTS BEFORE THE STOP. Reordered, the refusal costs an outage instead of
# nothing, on a host mid-upgrade with freshly swapped binaries.
# BOTH cli pre-flights, in one expression. Disabling only the `-x` check left the
# `migrate --help` probe to refuse a moment later with the same "nothing has been
# stopped" message, so the mutant survived — the guards overlap, and a mutation
# aimed at one of two overlapping guards measures neither.
mutate preflight-runs-after-the-stop adopt_user_tree.sh \
    "s@^if \[ ! -x \"\$CLI\" \]; then@if false; then@; s@^if ! \"\$CLI\" migrate --help >/dev/null 2>\&1; then@if false; then@" \
    "a missing cli refuses the rung before anything is stopped (case 25)"

mutate elevation-not-preflighted adopt_user_tree.sh \
    "s|^if ! elevate true >/dev/null 2>\&1; then|if false; then|" \
    "an unreachable root refuses the rung before anything is stopped (case 25b)"

# THE UPDATER MUST NEVER BE STOPPED — update.sh runs under it, so booting it out
# kills the process running the ladder.
mutate updater-stopped-too adopt_user_tree.sh \
    "s@stop \"burrowee-\$COMP.service\" 2>/dev/null@stop \"burrowee-\$COMP-updater.service\" 2>/dev/null@" \
    "only the daemon is stopped, never the updater (case 24b)"

# The substring collision, on the liveness side this time: with the terminator
# gone a running burrowee-edge-updater reads as a live burrowee-edge and the rung
# refuses forever on every host that takes push updates.
mutate liveness-match-not-terminated adopt_user_tree.sh \
    's@^    "burrowee-$COMP "[*] | [*]"/burrowee-$COMP "[*]) return 0 ;;@    *"burrowee-$COMP"*) return 0 ;;@' \
    "a running burrowee-<comp>-updater is not the daemon (case 24c)"

# The guard that makes a SHARED rung inert for a per-user component.
mutate same-tree-guard-removed adopt_user_tree.sh \
    "s|^    if ! is_a_destination \"\$_cand\"; then\$|    if true; then|" \
    "a component whose tree IS its own is skipped as a source, not copied onto itself (case 26c)"

# --- the one-source rule ----------------------------------------------------
#
# There used to be two candidates here, root's home first, and two mutants
# defending that precedence. Both are gone with the rule they defended: what has
# to be defended now is that root's home is NOT consulted, that a root login
# shell REFUSES rather than falling back to it, and that the refusal does not
# leak into the --applies probe as "nothing to adopt".

# THE DEFECT ITSELF, restored. Root's home was the first candidate, and on
# admin-kr it was a manual copy a crash-looping daemon had cut down to one line.
# Case 28a's fixtures differ byte for byte precisely so this is observable.
mutate roots-home-is-the-source-again adopt_user_tree.sh \
    "s|^elif _run_home=\"\$(running_user_home)\" .. \[ -n \"\$_run_home\" \]; then\$|elif _run_home=\"\$(root_home)\" \&\& [ -n \"\$_run_home\" ]; then|" \
    "the source is the RUNNING USER's home; root's is never a candidate (case 28a)"

# THE SILENT FALLBACK, restored. With the euid test gone a root login shell
# resolves \$HOME — root's — and adopts it without saying anything, which is the
# exact shape of the defect one level up.
mutate root-login-falls-back-to-HOME lib_paths.sh \
    "s|^        if \[ \"\$(id -u)\" = 0 \]; then return 1; fi\$|        :|" \
    "a root login shell has NO running user and refuses; it never falls back to root's \$HOME (case 28e)"

# The refusal must not become the probe's answer: run.sh reads exit 1 from
# --applies as "does not apply", so folding "no running user" into "nothing to
# adopt" skips the rung silently on the host that cannot name its own source.
mutate no-running-user-reads-as-nothing-to-adopt adopt_user_tree.sh \
    "s|^    \[ \"\$NO_RUNNING_USER\" = 1 \] .. return 1\$|    :|" \
    "no running user answers STILL NEEDED, never 'nothing to adopt' (case 28f)"

# Under `curl … | sudo sh` \$HOME is root's and \$SUDO_USER names the account whose
# tree matters. Case 28h seeds a DIFFERENT enrolled tree at \$HOME so the two
# answers are distinguishable.
mutate running-user-home-ignores-SUDO_USER lib_paths.sh \
    "s|^    _ruh_user=\"\${SUDO_USER:-}\"\$|    _ruh_user=\"\"|" \
    "the running user under sudo is \$SUDO_USER, not \$HOME (case 28h)"

# ADOPT_FROM is the operator naming the tree. A rung that then looked for a
# better one would be second-guessing the person recovering the host.
mutate adopt_from_ignored adopt_user_tree.sh \
    "s|^if \[ -n \"\${ADOPT_FROM:-}\" \]; then\$|if false; then|" \
    "\$ADOPT_FROM overrides the whole selection (case 28c)"

# --- the system scheme ------------------------------------------------------
# An absent machine root is the state to migrate FROM, not a tree in the wrong
# place. Skipping there refuses the rung on exactly the hosts that need it.
mutate system-absent-root-skips-everything run.sh \
    "s|^if \[ ! -d \"\$COMP_HOME\" \] .. \[ \"\${COMP_HOME_SCHEME:-user}\" = system \]; then\$|if false; then|" \
    "an absent system config root is evaluated, not skipped (case 29d)"

# Pairing a named tree with a defaulted one is how a run reads config from one
# install and writes state into another.
mutate half-a-pair-accepted run.sh \
    "s|^    if \[ -n \"\${COMP_HOME:-}\" \] .. \[ -z \"\${COMP_DATA:-}\" \]; then\$|    if false; then|" \
    "a system-scheme run given \$COMP_HOME without \$COMP_DATA refuses (case 29c)"

# A stray \$COMP_DATA in a caller's environment must not split a component that
# never made the split.
mutate user_scheme_honours_comp_data run.sh \
    "s|^    COMP_DATA=\"\$COMP_HOME\"\$|    COMP_DATA=\"\${COMP_DATA:-\$COMP_HOME}\"|" \
    "a user/root-scheme component ignores \$COMP_DATA entirely (case 29b)"

# --- the runner's half of the stop contract ---------------------------------

mutate stop-declaration-ignored run.sh \
    "s|^    for _sts in \$SERVICE_STOP_RUNGS; do|    for _sts in ; do|" \
    "the runner announces the stop and says the daemon is down afterwards (case 22b)"

mutate stop-declaration-always-fires run.sh \
    "s|^    return 1\$|    return 0|" \
    "a component that declares no stop rung gets the unchanged closing line (case 26)"

mutate stop-crosscheck-decorative run.sh \
    "s|^    if \[ \"\$_ssr_found\" != 1 \]; then|    if false; then|" \
    "a SERVICE_STOP_RUNGS name that is not in the ledger refuses the run (case 27)"

mutate upgrade-exit2-note-unconditional upgrade.sh \
    "s|^    if \[ -n \"\${SERVICE_STOP_RUNGS:-}\" \]; then|    if true; then|" \
    "cli's operator override still says nothing was left down (case 26b)"

# --- the forced adoption ----------------------------------------------------
# The whole point of forcing: a tree adopted from the WRONG source is repaired by
# re-running the migration. A rung that announces a forced run and then invokes
# the ordinary never-overwriting copy leaves the host exactly as broken.
mutate forced-run-drops-the-flag adopt_user_tree.sh \
    "s|^    MIGRATE_FORCE=\"--force\"\$|    MIGRATE_FORCE=\"\"|" \
    "a forced run passes --force to the cli and the destination changes (case 30b)"

# The other direction, and the guard on the change itself: never-overwrite is
# still what an ordinary ladder run gets.
mutate every-run-forces adopt_user_tree.sh \
    "s|^FORCED=0\$|FORCED=1|" \
    "an unforced ladder run never passes --force (case 30c)"

# --applies must stop treating "the destination already holds an identity" as
# "already done" when forcing — that state IS what a wrongly-adopted host looks
# like, so keeping the check declines the rung on every host the flag is for.
mutate forced-applies-still-checks-already-adopted adopt_user_tree.sh \
    "s|^    if \[ \"\$FORCED\" = 1 \]; then\$|    if false; then|" \
    "a forced run with NO named version is still selected on a populated destination (case 30e)"

# Forcing widens what may be OVERWRITTEN, never what may be read: with no source
# tree there is nothing to copy, and a receipt for that is a lie.
mutate forced-applies-ignores-nothing-to-adopt adopt_user_tree.sh \
    "s|^        if nothing_to_adopt; then exit 1; fi\$|        if false; then exit 1; fi|" \
    "a forced run with an unenrolled source still declines (case 30d)"

# The runner's half. Without the export the rung can never learn it was forced,
# and upgrade.sh becomes the no-op it already was. NO ANCHORS AND NO TRAILING
# BACKSLASH in the pattern: the assignment sits on a line-continuation, and an
# expression that has to spell that backslash is one sed rejects — which the
# harness scores as a broken mutant, not as a killed one.
mutate runner-never-declares-force run.sh \
    "s|MIGRATION_FORCED=\"\$RERUN_RECORDED\"|MIGRATION_FORCED=\"0\"|" \
    "--rerun-recorded reaches the rungs as \$MIGRATION_FORCED (case 30b/30e)"

# And the announcement: an operator about to lose a node identity has to read it
# while the daemon is still up.
mutate forced-run-says-nothing adopt_user_tree.sh \
    "s|^    say \"FORCED RUN|    : \"FORCED RUN|" \
    "a forced run announces itself before the stop (case 30b)"

echo "== $RUN mutants, $SURVIVORS survived =="
[ "$SURVIVORS" = 0 ] || exit 1
