#!/bin/sh
# tools/install-migration-consent.test.sh — the MIGRATION-side consent gate.
#
#     sh tools/install-migration-consent.test.sh
#     dash tools/install-migration-consent.test.sh
#
# WHY A SECOND GATE. There are two places an install stops the gateway, and the
# restart is only the later one. Gateway's own migration runner (migrations/
# run.sh, from the gateway repo — NOT the shared ladder, which gateway does not
# take: tools/payload.sh's takes_shared_ladder covers edge, cli and relay only)
# stops the daemon to copy state at rest, a long way before load_units restarts
# it. On a host administered THROUGH that gateway, that stop takes the operator's
# session, so the Phase 3 consent prompt is read from a terminal that is already
# gone: an empty answer, which is a decline. A gate asked after the connection is
# gone is not a gate.
#
# So install.sh asks the runner FIRST — `run.sh --probe-pending`, a read-only
# mode that walks the ladder and reports whether a rung is pending without
# touching anything — and prompts only when the answer is "a real run would stop
# the gateway". Every check here is about should_ask_before_migration, which is
# the whole of the new decision.
#
# WHAT IS DRIVEN, AND WHY NOT AN END-TO-END INSTALL. The function is exercised
# directly through install.sh's own BURROWEE_SOURCE_ONLY seam, the same way
# guard-rollback.test.sh drives verify_placement and verify_units. The reason is
# has_tty: the branch that matters most is the one taken when a terminal EXISTS,
# and a suite that runs under CI has none to offer. Stubbing has_tty in the
# snippet is what makes that branch reachable at all — and t_gate_reads_has_tty
# below pins that the real function still consults it, so the stub is standing in
# for something that is really there rather than for a fiction.
#
# THE RUNNER IS A STUB HERE ON PURPOSE. Whether the probe's ANSWER is correct is
# the gateway repo's question, and its suite (internal/updatescript/
# migration_probe_test.go) drives the real runner in both modes against one host
# and requires them to agree. What this file owns is the other half: that
# install.sh asks, that it prompts on 10 and only on 10, and that every way of
# not knowing lands on "behave exactly as today".
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
INSTALL="$HERE/inner/gateway/install.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

# ---------------------------------------------------------------------------
# stage_runner <root> <exit-code> [omit-flag]
#
# A migrations/run.sh beside a staged installer. It records EVERY invocation
# (with its arguments and the environment install.sh handed it) so a check can
# assert the probe was never forked at all, which is a different claim from "it
# was forked and answered no".
#
# With a third argument the stub does NOT contain the string --probe-pending
# anywhere. That is the pre-change payload: install.sh reads a runner before it
# hands it the flag, because the FIRST shipped gateway runner (gateway #246)
# parsed no arguments whatsoever — given the flag it would have ignored it and
# RUN THE LADDER, stopping the daemon at the exact moment the probe exists to
# warn about. keep_installer_copy leaves a runner under $GW_HOME for later
# `service install` runs, so a runner that old is reachable from a real host and
# not only from history.
# ---------------------------------------------------------------------------
stage_runner() {
    _sr_root="$1"; _sr_exit="$2"; _sr_omit="${3:-}"
    mkdir -p "$_sr_root/stage/migrations"
    {
        echo '#!/bin/sh'
        echo "echo \"ARGS=\$*\" >> '$_sr_root/runner.log'"
        echo "echo \"GW_HOME=\$GW_HOME\" >> '$_sr_root/runner.log'"
        echo "echo \"CONFIG=\$BURROWEE_SYSTEM_CONFIG_DIR\" >> '$_sr_root/runner.log'"
        echo "echo \"DATA=\$BURROWEE_SYSTEM_DATA_DIR\" >> '$_sr_root/runner.log'"
        echo "echo \"PREFIX=\$PREFIX\" >> '$_sr_root/runner.log'"
        if [ -z "$_sr_omit" ]; then
            # The token install.sh reads the file for. Spelled in a comment so
            # the stub carries it without having to implement the mode.
            echo '# understands --probe-pending'
        fi
        echo "exit $_sr_exit"
    } > "$_sr_root/stage/migrations/run.sh"
    chmod 0755 "$_sr_root/stage/migrations/run.sh"
}

# ---------------------------------------------------------------------------
# ask <root> <snippet-prefix> — run should_ask_before_migration with install.sh
# sourced, from the staged directory (so the REAL migration_runner resolves the
# stub through its own `dirname $0`/migrations/run.sh, rather than a test
# override standing in for it). Echoes the return code.
#
# <snippet-prefix> is shell run after sourcing and before the call: it is where
# has_tty is stubbed. Each caller states its own tty situation rather than
# inheriting one, because "there is nobody to warn" is itself one of the
# behaviours under test.
# ---------------------------------------------------------------------------
ask() {
    _a_root="$1"; _a_pre="$2"
    (
        cd "$_a_root/stage" && \
        BURROWEE_SOURCE_ONLY=1 \
        HOME="$_a_root/home" \
        BURROWEE_BIN_DIR="$_a_root/bin" \
        BURROWEE_SYSTEM_CONFIG_DIR="$_a_root/etc/gateway" \
        BURROWEE_SYSTEM_DATA_DIR="$_a_root/var/gateway" \
        sh -c ". '$INSTALL'; $_a_pre; if should_ask_before_migration; then echo 0; else echo \$?; fi"
    )
}

new_root() {
    _n="$(mktemp -d)"
    mkdir -p "$_n/home" "$_n/bin"
    echo "$_n"
}

# tty_yes is the stub that puts an operator in front of the install. It replaces
# has_tty ONLY — migration_sudo and consent_to_sever consult the same function,
# so a run that takes this branch is the same shape a real interactive host is.
tty_yes='has_tty() { return 0; }'
tty_no='has_tty() { return 1; }'

# ---------------------------------------------------------------------------
# The four probe answers.
# ---------------------------------------------------------------------------

# 10 is the only code that prompts. It is the runner saying "a real run would
# stop the gateway", which on a tunnelled host means "and take this session".
t_pending_asks() {
    _r="$(new_root)"
    stage_runner "$_r" 10
    _rc="$(ask "$_r" "$tty_yes")"
    [ "$_rc" = 0 ] || fail "a pending migration (probe 10) did not reach the consent prompt (rc=$_rc)"
    grep -q -- '--probe-pending' "$_r/runner.log" 2>/dev/null \
        || fail "install.sh never asked the runner: $(cat "$_r/runner.log" 2>/dev/null || echo '<no log>')"
    rm -rf "$_r"
}

# 11 must be silent. An install with nothing pending has to behave exactly as it
# did before this gate existed — a prompt on every install would be a warning
# that is usually false, and an operator who learns to answer it without reading
# is worse off than one who was never asked.
t_nothing_pending_is_silent() {
    _r="$(new_root)"
    stage_runner "$_r" 11
    _rc="$(ask "$_r" "$tty_yes")"
    [ "$_rc" != 0 ] || fail "an install with nothing pending prompted anyway"
    grep -q -- '--probe-pending' "$_r/runner.log" 2>/dev/null \
        || fail "the runner was not asked at all, so this check proves nothing"
    rm -rf "$_r"
}

# 12 is "the ladder could not be evaluated" — the refusals a real run answers 1
# to. It does NOT prompt: a real run reaches the same refusal, stops nothing, and
# exits the installer. Today's install prints that refusal and gives up, and this
# gate must not put a question in front of it.
t_cannot_evaluate_does_not_ask() {
    _r="$(new_root)"
    stage_runner "$_r" 12
    _rc="$(ask "$_r" "$tty_yes")"
    [ "$_rc" != 0 ] || fail "a ladder that could not be evaluated (probe 12) still prompted"
    rm -rf "$_r"
}

# 64 is what a runner NEW enough to parse arguments but OLD enough not to know
# this mode answers: usage_error, exit 64, nothing evaluated. Same verdict —
# proceed as today.
t_unrecognised_mode_does_not_ask() {
    _r="$(new_root)"
    stage_runner "$_r" 64
    _rc="$(ask "$_r" "$tty_yes")"
    [ "$_rc" != 0 ] || fail "a runner that refused the mode (exit 64) still produced a prompt"
    rm -rf "$_r"
}

# And nothing invented later is read as a yes either: the gate is `= 10`, not
# `!= 11`. A future runner's new code must fall to "cannot tell".
t_only_ten_asks() {
    _r="$(new_root)"
    stage_runner "$_r" 13
    _rc="$(ask "$_r" "$tty_yes")"
    [ "$_rc" != 0 ] || fail "an unknown probe code (13) was read as a pending migration"
    rm -rf "$_r"
}

# ---------------------------------------------------------------------------
# THE OLD RUNNER MUST NEVER BE INVOKED, not merely disbelieved.
#
# This is the one case where getting it wrong is not a missing warning but an
# outage: gateway #246's runner ignored argv entirely, so `run.sh
# --probe-pending` would have walked the ladder for real and stopped the daemon.
# The check is therefore on the LOG — that the file was never executed — and not
# on the return code, which would be identical either way.
# ---------------------------------------------------------------------------
t_runner_without_the_mode_is_never_run() {
    _r="$(new_root)"
    stage_runner "$_r" 10 omit
    _rc="$(ask "$_r" "$tty_yes")"
    [ "$_rc" != 0 ] || fail "a runner that does not carry the mode was treated as having answered yes"
    [ ! -s "$_r/runner.log" ] \
        || fail "a runner with no --probe-pending support WAS executed: $(cat "$_r/runner.log")"
    rm -rf "$_r"
}

# A bundle with no migrations/ at all (a $GW_HOME self-copy from an install that
# predates the directory) is the same verdict, reached one step earlier.
t_absent_runner_does_not_ask() {
    _r="$(new_root)"
    mkdir -p "$_r/stage"
    _rc="$(ask "$_r" "$tty_yes")"
    [ "$_rc" != 0 ] || fail "a bundle carrying no runner still produced a prompt"
    rm -rf "$_r"
}

# ---------------------------------------------------------------------------
# NON-INTERACTIVE RUNS MUST NOT BLOCK — and must not even fork the probe.
#
# Console pushes, CI and `curl … | sh` have no tty; BURROWEE_ASSUME_YES=1 is the
# scriptable override for a host that has one. consent_to_sever returns
# immediately in both cases, so the probe's answer would be discarded — and a
# gate that forked it anyway would be paying for an answer nobody can act on, on
# the exact path where an unexpected prompt would hang every automated install.
# The log is the assertion: not asked, not merely not obeyed.
# ---------------------------------------------------------------------------
t_no_tty_never_probes() {
    _r="$(new_root)"
    stage_runner "$_r" 10
    _rc="$(ask "$_r" "$tty_no")"
    [ "$_rc" != 0 ] || fail "a run with no terminal reached the consent prompt"
    [ ! -s "$_r/runner.log" ] \
        || fail "the probe was forked on a run with nobody to warn: $(cat "$_r/runner.log")"
    rm -rf "$_r"
}

t_assume_yes_never_probes() {
    _r="$(new_root)"
    stage_runner "$_r" 10
    _rc="$(ask "$_r" "BURROWEE_ASSUME_YES=1; $tty_yes")"
    [ "$_rc" != 0 ] || fail "BURROWEE_ASSUME_YES=1 still reached the consent prompt"
    [ ! -s "$_r/runner.log" ] \
        || fail "the probe was forked under BURROWEE_ASSUME_YES: $(cat "$_r/runner.log")"
    rm -rf "$_r"
}

# ---------------------------------------------------------------------------
# THE PROBE MUST ANSWER ABOUT THE HOST THE RUN WILL MIGRATE.
#
# migrate_from_legacy resolves $GW_HOME, the two system roots and a PREFIX
# derived from $BIN_DIR, and hands all of them to the runner. A probe that let
# any of those default differently would be answering about a different tree than
# the run it speaks for — the same defect run_migration's own header records for
# the --applies probe inside the runner, one layer up.
# ---------------------------------------------------------------------------
t_probe_env_matches_the_real_run() {
    _r="$(new_root)"
    stage_runner "$_r" 10
    ask "$_r" "$tty_yes" > /dev/null
    for _want in \
        "GW_HOME=$_r/home/.burrowee/gateway" \
        "CONFIG=$_r/etc/gateway" \
        "DATA=$_r/var/gateway" \
        "PREFIX=$_r"
    do
        grep -qx -- "$_want" "$_r/runner.log" 2>/dev/null \
            || fail "the probe did not get $_want; it saw: $(cat "$_r/runner.log" 2>/dev/null || echo '<no log>')"
    done
    rm -rf "$_r"
}

# ---------------------------------------------------------------------------
# SOURCE-LEVEL: the gate has to be in the right place, and the stub above has to
# be standing in for something real.
# ---------------------------------------------------------------------------

# The stub is only honest if the function really consults has_tty. Without this
# every tty check above would be asserting about a branch install.sh does not
# have.
t_gate_reads_has_tty() {
    _body="$(sed -n '/^should_ask_before_migration() {/,/^}/p' "$INSTALL" | grep -v '^[[:space:]]*#')"
    [ -n "$_body" ] || { fail "install.sh has no should_ask_before_migration"; return; }
    printf '%s\n' "$_body" | grep -q 'has_tty' \
        || fail "should_ask_before_migration does not gate on has_tty"
    printf '%s\n' "$_body" | grep -q 'BURROWEE_ASSUME_YES' \
        || fail "should_ask_before_migration offers no non-interactive override"
    printf '%s\n' "$_body" | grep -q '= 10' \
        || fail "should_ask_before_migration does not gate on the probe's pending code"
}

# ORDER IS THE WHOLE POINT. The question must be asked before the step that
# severs, and after the guard is armed — a prompt declined before guard_arm has
# nothing to hand the undo to, and one asked after migrate_from_legacy is asked
# of a connection that is already gone.
t_gate_runs_before_the_migration_and_after_the_guard() {
    _guard="$(grep -n '^guard_arm$' "$INSTALL" | head -1 | cut -d: -f1)"
    _ask="$(grep -n '^if should_ask_before_migration; then$' "$INSTALL" | head -1 | cut -d: -f1)"
    _mig="$(grep -n '^migrate_from_legacy$' "$INSTALL" | tail -1 | cut -d: -f1)"
    [ -n "$_guard" ] || { fail "install.sh never arms the guard"; return; }
    [ -n "$_ask" ]   || { fail "install.sh never calls should_ask_before_migration at top level"; return; }
    [ -n "$_mig" ]   || { fail "install.sh never calls migrate_from_legacy at top level"; return; }
    [ "$_guard" -lt "$_ask" ] \
        || fail "the consent question (line $_ask) is asked before the guard is armed (line $_guard)"
    [ "$_ask" -lt "$_mig" ] \
        || fail "the consent question (line $_ask) is asked after migrate_from_legacy (line $_mig)"
}

# It must ask for the MIGRATION cause, not the restart one: consent_to_sever
# renders a different reason for each, and the migration's is the one that is
# true here.
t_gate_names_the_migration_cause() {
    grep -q '^    consent_to_sever migration$' "$INSTALL" \
        || fail "install.sh does not call consent_to_sever with the 'migration' cause"
}

# ---------------------------------------------------------------------------
# THE PROMPT MUST NOT GIVE THE RESTART'S ADVICE AT THE MIGRATION.
#
# "you do not need to stay connected" is true at the Phase 3 restart: the
# handoff is written, so the guard CARRIES THE INSTALL THROUGH. At the
# migration it is the reverse — the stop comes before the handoff, so a
# severed session kills the installer at phase `replacing` and the guard's
# watch loop rolls the install BACK. Printing the restart's reassurance there
# told the operator the opposite of what happens, at the moment they decide.
#
# The two arms are one `case` apart, which is exactly the kind of split a
# later edit re-merges "to remove the duplication". These checks are what make
# that visible instead of silent.
# ---------------------------------------------------------------------------

# closing_advice <migration|restart> — the printf lines one cause contributes
# to the paragraph between "Continuing will drop this connection" and the
# shared transaction/guard-status block. Anchored to those two lines rather
# than to the function body, so it stays correct if the function grows.
closing_advice() {
    _ca_want="$1"
    sed -n "/printf 'Continuing will drop this connection/,/printf '  transaction/p" "$INSTALL" \
        | awk -v want="$_ca_want" '
            /^[[:space:]]*migration\)/ { arm = "migration"; next }
            /^[[:space:]]*\*\)/       { arm = "restart";   next }
            /^[[:space:]]*;;/           { arm = "";          next }
            arm == want                 { print }
        '
}

t_causes_render_different_closing_advice() {
    _mig="$(closing_advice migration)"
    _res="$(closing_advice restart)"
    [ -n "$_mig" ] || { fail "the prompt has no migration-specific closing advice"; return; }
    [ -n "$_res" ] || { fail "the prompt has no restart closing advice"; return; }
    [ "$_mig" != "$_res" ] \
        || fail "both causes print the same closing advice — the migration arm has been re-merged"
}

# The restart's text is correct where it is and must not move.
t_restart_keeps_its_advice() {
    if ! closing_advice restart | grep -q 'you do not need to stay connected'; then
        fail "the restart cause lost 'you do not need to stay connected', which is true there"
    fi
}

# The migration's must not claim it, and must name the shape that does work.
t_migration_advice_is_honest() {
    _mig="$(closing_advice migration)"
    if printf '%s\n' "$_mig" | grep -q 'you do not need to stay connected'; then
        fail "the migration cause still tells the operator they may disconnect — the guard rolls that install BACK"
    fi
    if ! printf '%s\n' "$_mig" | grep -q 'nohup'; then
        fail "the migration cause does not name a detached re-run, so it says what goes wrong and not what to do"
    fi
    if ! printf '%s\n' "$_mig" | grep -q 'BACK'; then
        fail "the migration cause does not say the install is rolled back rather than finished"
    fi
}

t_pending_asks
t_nothing_pending_is_silent
t_cannot_evaluate_does_not_ask
t_unrecognised_mode_does_not_ask
t_only_ten_asks
t_runner_without_the_mode_is_never_run
t_absent_runner_does_not_ask
t_no_tty_never_probes
t_assume_yes_never_probes
t_probe_env_matches_the_real_run
t_gate_reads_has_tty
t_gate_runs_before_the_migration_and_after_the_guard
t_gate_names_the_migration_cause
t_causes_render_different_closing_advice
t_restart_keeps_its_advice
t_migration_advice_is_honest

if [ "$fails" -ne 0 ]; then
    printf '%s check(s) failed\n' "$fails" >&2
    exit 1
fi
echo "install-migration-consent: all checks passed"
