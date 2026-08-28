#!/usr/bin/env bash
# release.command.test.sh — unit tests for tools/release.command's own logic.
#
# NOTHING is cut. The launcher is copied into a THROWAWAY repo under a temp dir
# whose tools/release.sh is a stub that records the arguments it was handed and
# returns; the real tools/release.sh is never invoked, nothing is built, signed,
# notarized, pushed or published, and no repository of this project is touched —
# not even to write a log or a lock, both of which land in the temp tree.
#
# Two things make the launcher runnable here at all, and neither edits it:
#
#   - It refuses a non-Aqua session in its first four lines of work, so a stub
#     `launchctl` first on PATH decides the session. That is the guard's own
#     contract, and one case below drives it the other way to prove the stub is
#     not just making the guard vacuous.
#   - It refuses when stdin is not a terminal, because LaunchServices always
#     gives it one. `script -q /dev/null` allocates a pty and propagates the
#     child's exit status, so the launcher runs exactly as opened, unmodified.
#
# Every case that reaches the cut loop passes --dry-run: that is the branch that
# skips the push path, and the push path is the only code here that calls git.
# git is reached by ABSOLUTE path (/usr/bin/git, deliberately — the launcher
# cannot trust the PATH its env file sets), so it cannot be stubbed the way
# release.sh is, and pushing is not something a test may do on a whim. The
# marker/push half is therefore out of scope for this file; see the note at the
# bottom.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="${HERE}/release.command"
[ -r "${LAUNCHER}" ] || { echo "FAIL: cannot read ${LAUNCHER}"; exit 1; }

fail=0
check() { # check <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi
}
check_contains() { # check_contains <label> <haystack> <needle>
    case "$2" in
        *"$3"*) echo "ok: $1" ;;
        *) echo "FAIL: $1 — '$2' does not contain '$3'"; fail=1 ;;
    esac
}

WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT

STUBS="${WORK}/stubs"
mkdir -p "${STUBS}"

# set_domain <name> — what `launchctl managername` reports to the launcher.
set_domain() {
    { echo '#!/bin/sh'
      printf 'printf "%%s\\n" %s\n' "'$1'"
      echo 'exit 0'
    } > "${STUBS}/launchctl"
    chmod 0755 "${STUBS}/launchctl"
}
set_domain Aqua

# The throwaway repo: the launcher plus a release.sh that cuts nothing.
REPO="${WORK}/repo"
mkdir -p "${REPO}/tools"
cp "${LAUNCHER}" "${REPO}/tools/release.command"
CALLS="${WORK}/calls"
export RELEASE_STUB_CALLS="${CALLS}"
cat > "${REPO}/tools/release.sh" <<'STUB'
#!/usr/bin/env bash
# Stub. Records its arguments; builds, signs, notarizes and publishes nothing.
printf '%s\n' "$*" >> "${RELEASE_STUB_CALLS}"
echo "stub release.sh: $*"
exit "${RELEASE_STUB_RC:-0}"
STUB

# The env file the launcher sources. Deliberately holds no machine facts: this
# test asserts flow, and a real release.env is a machine's private file.
ENV_FILE="${WORK}/release.env"
printf '# test env — intentionally empty of machine facts\n' > "${ENV_FILE}"

LOG="${WORK}/release.log"

# run_launcher <request-file> [env-file] — open the launcher the way
# LaunchServices does and return its exit status.
run_launcher() {
    rm -f "${LOG}" "${LOG}.prev"
    : > "${CALLS}"
    RELEASE_ENV="${2:-${ENV_FILE}}" \
    RELEASE_REQUEST="$1" \
    RELEASE_LOG="${LOG}" \
    TERM_PROGRAM="${TEST_TERM_PROGRAM:-}" \
    RELEASE_TERMINAL_PREFS="${TEST_TERMINAL_PREFS:-${WORK}/no-such-prefs.plist}" \
    PATH="${STUBS}:/usr/bin:/bin" \
        /usr/bin/script -q /dev/null /bin/bash "${REPO}/tools/release.command" \
        </dev/null >/dev/null 2>&1
}

log_text() { cat "${LOG}" 2>/dev/null; }
# The sentinel a watcher blocks on. Counted, not merely matched: two of them is
# as broken as none — the watcher would read the first and act on a run that is
# still going.
sentinel_count() { grep -c '^RELEASE-EXIT:' "${LOG}" 2>/dev/null | tr -d '[:space:]'; }
sentinel_code()  { sed -n 's/^RELEASE-EXIT://p' "${LOG}" 2>/dev/null | tail -1; }
# LAST, not merely present. KEEP_WINDOW holds the run open AFTER the sentinel,
# and the prompt it prints must go to the terminal and not into the file: a
# watcher that reads the log has to be able to stop at RELEASE-EXIT: while the
# window is still sitting there waiting for a human.
sentinel_is_last() { tail -1 "${LOG}" 2>/dev/null | sed -n 's/^\(RELEASE-EXIT\):.*/\1/p'; }
calls() { cat "${CALLS}" 2>/dev/null; }

# check_refusal <label> <rc> — a refusal is not just a non-zero exit: the log
# must end in exactly ONE sentinel and it must carry the same code, or the
# watcher either blocks forever or reports the wrong outcome. This is the whole
# reason the launcher emits the sentinel from a single EXIT trap.
check_refusal() {
    local label="$1" rc="$2"
    if [ "${rc}" -eq 0 ]; then
        echo "FAIL: ${label} — exited 0, expected a refusal"; fail=1
    else
        echo "ok: ${label} refused (rc ${rc})"
    fi
    check "${label}: exactly one RELEASE-EXIT line" "$(sentinel_count)" "1"
    check "${label}: sentinel carries the refusal code" "$(sentinel_code)" "${rc}"
    check "${label}: sentinel is the last line" "$(sentinel_is_last)" "RELEASE-EXIT"
}

echo "--- session guard -----------------------------------------------------"

# Drive the guard the way it will really fail before trusting the stub anywhere
# else: if `launchctl managername` reporting System did NOT refuse, every case
# below would be running against a launcher whose first gate is inert.
REQ_OK="${WORK}/req-ok"
printf 'COMPONENTS="cli"\nFLAGS="--dry-run"\n' > "${REQ_OK}"
set_domain System
run_launcher "${REQ_OK}"; rc=$?
check_refusal "System session" "${rc}"
check_contains "System session names the domain it got" "$(log_text)" "session-domain: System"
check_contains "System session names the domain it needs" "$(log_text)" "need Aqua"
check "System session cuts nothing" "$(calls)" ""
# The session check runs BEFORE the lock is taken, so a refused run must leave
# no lock for the next one to trip over.
check "System session takes no lock" "$([ -d "${REPO}/.release.lock" ] && echo yes || echo no)" "no"
set_domain Aqua

echo "--- inputs ------------------------------------------------------------"

# An env file that is not there is fatal: it carries the toolchain PATH and the
# signing backends, so continuing without it cuts with whatever happens to be
# on PATH.
run_launcher "${REQ_OK}" "${WORK}/no-such-env"; rc=$?
check_refusal "missing env file" "${rc}"
check_contains "missing env file is named" "$(log_text)" "env file not readable"
check "missing env file cuts nothing" "$(calls)" ""

run_launcher "${WORK}/no-such-request"; rc=$?
check_refusal "missing request file" "${rc}"
check_contains "missing request file is named" "$(log_text)" "request file not readable"
check "missing request file cuts nothing" "$(calls)" ""

# Present but unreadable is the same answer — the launcher sources this file, so
# "exists" is not the question it needs answered.
REQ_LOCKED="${WORK}/req-unreadable"
printf 'COMPONENTS="cli"\nFLAGS="--dry-run"\n' > "${REQ_LOCKED}"
chmod 000 "${REQ_LOCKED}"
run_launcher "${REQ_LOCKED}"; rc=$?
chmod 644 "${REQ_LOCKED}"
check_refusal "unreadable request file" "${rc}"
check_contains "unreadable request file is named" "$(log_text)" "request file not readable"

# A request that sources cleanly but names nothing to cut. Without this the
# launcher would run its whole loop zero times and exit 0 — a "successful"
# release that released nothing.
REQ_EMPTY="${WORK}/req-empty"
printf 'FLAGS="--dry-run"\n' > "${REQ_EMPTY}"
run_launcher "${REQ_EMPTY}"; rc=$?
check_refusal "request names no COMPONENTS" "${rc}"
check_contains "empty request is explained" "$(log_text)" "names no COMPONENTS"
check "empty request cuts nothing" "$(calls)" ""

echo "--- COMPONENTS validation ---------------------------------------------"

# THE WEDGE THIS FILE EXISTS TO PREVENT. `all` is a real release.sh argument, so
# nothing downstream rejects it — it cuts every component in one process with no
# push between, leaves HEAD reading [RELEASED: <last>] and the marker test unable
# to match, and reports success sitting on four unpushed markers. The refusal has
# to say why AND spell the replacement, or the operator retries the same request.
REQ_ALL="${WORK}/req-all"
printf 'COMPONENTS="all"\nFLAGS="--dry-run"\n' > "${REQ_ALL}"
run_launcher "${REQ_ALL}"; rc=$?
check_refusal "COMPONENTS=all" "${rc}"
check_contains "all: says why it is refused" "$(log_text)" "no push between"
check_contains "all: says what it leaves behind" "$(log_text)" "markers unpushed"
check_contains "all: names the individual components" "$(log_text)" "COMPONENTS=\"cli gateway edge agent\""
check "all: cuts nothing" "$(calls)" ""

REQ_BOGUS="${WORK}/req-bogus"
printf 'COMPONENTS="bogus"\nFLAGS="--dry-run"\n' > "${REQ_BOGUS}"
run_launcher "${REQ_BOGUS}"; rc=$?
check_refusal "unknown component" "${rc}"
check_contains "unknown component is named" "$(log_text)" "unknown component: bogus"
check "unknown component cuts nothing" "$(calls)" ""

# The validation is a loop, not a test of the first word: a bad component behind
# a good one must still refuse, and must refuse BEFORE the good one is cut —
# otherwise the batch publishes cli and then aborts, which is the state the
# launcher's own error text tells the operator to avoid.
REQ_MIXED="${WORK}/req-mixed"
printf 'COMPONENTS="cli nosuch"\nFLAGS="--dry-run"\n' > "${REQ_MIXED}"
run_launcher "${REQ_MIXED}"; rc=$?
check_refusal "bad component behind a good one" "${rc}"
check_contains "the bad one is named, not the good one" "$(log_text)" "unknown component: nosuch"
check "nothing is cut before validation finishes" "$(calls)" ""

# The negative control for all of the above: the accepted names must actually be
# accepted, and each must reach release.sh once, in order, carrying FLAGS.
REQ_TWO="${WORK}/req-two"
printf 'COMPONENTS="cli gateway"\nFLAGS="--dry-run"\n' > "${REQ_TWO}"
run_launcher "${REQ_TWO}"; rc=$?
check "cli gateway accepted (rc)" "${rc}" "0"
check "cli gateway: exactly one RELEASE-EXIT line" "$(sentinel_count)" "1"
check "cli gateway: sentinel says success" "$(sentinel_code)" "0"
check "cli gateway: both cut, in order, with FLAGS" "$(calls)" "cli --channel stable --dry-run
gateway --channel stable --dry-run"
check_contains "cli gateway: --dry-run is announced" "$(log_text)" "no marker will be pushed"

# Every accepted name, one run each, so the list cannot rot to a subset.
for comp in cli gateway edge agent relay; do
    REQ_ONE="${WORK}/req-${comp}"
    printf 'COMPONENTS="%s"\nFLAGS="--dry-run"\n' "${comp}" > "${REQ_ONE}"
    run_launcher "${REQ_ONE}"; rc=$?
    check "component '${comp}' is accepted (rc)" "${rc}" "0"
    check "component '${comp}' reaches release.sh" "$(calls)" "${comp} --channel stable --dry-run"
done

echo "--- CHANNEL validation --------------------------------------------------"

# CHANNEL="beta" passes --channel beta through to every cut, same position as
# the stable default (right after the component, ahead of FLAGS).
REQ_BETA="${WORK}/req-beta"
printf 'COMPONENTS="cli"\nFLAGS="--dry-run"\nCHANNEL="beta"\n' > "${REQ_BETA}"
run_launcher "${REQ_BETA}"; rc=$?
check "CHANNEL=beta accepted (rc)" "${rc}" "0"
check "CHANNEL=beta: --channel beta reaches release.sh" "$(calls)" "cli --channel beta --dry-run"
check_contains "CHANNEL=beta is echoed in the request line" "$(log_text)" "channel=beta"

# An unrecognised channel is refused BEFORE anything builds — same shape as the
# COMPONENTS validation above (checked ahead of the cut loop, not left to
# release.sh's own --channel refusal to catch it after work has started).
REQ_NIGHTLY="${WORK}/req-nightly"
printf 'COMPONENTS="cli"\nFLAGS="--dry-run"\nCHANNEL="nightly"\n' > "${REQ_NIGHTLY}"
run_launcher "${REQ_NIGHTLY}"; rc=$?
check_refusal "CHANNEL=nightly" "${rc}"
check_contains "CHANNEL=nightly is named" "$(log_text)" "CHANNEL must be stable or beta (got 'nightly')"
check "CHANNEL=nightly cuts nothing" "$(calls)" ""

# A request with no CHANNEL= line at all (every request file above this point)
# defaults to stable — the negative control that the new validation didn't
# silently start requiring the key.
REQ_NOCHANNEL="${WORK}/req-nochannel"
printf 'COMPONENTS="cli"\nFLAGS="--dry-run"\n' > "${REQ_NOCHANNEL}"
run_launcher "${REQ_NOCHANNEL}"; rc=$?
check "no CHANNEL= line accepted (rc)" "${rc}" "0"
check "no CHANNEL= line defaults to stable" "$(calls)" "cli --channel stable --dry-run"

echo "--- window disposition ---------------------------------------------"

# NOTHING here reads the operator's real Terminal preferences: every case points
# the launcher at a plist this test built, and the default for every OTHER case
# in this file is a path that does not exist. The launcher only ever reads that
# file — it must never write it, and a test that could write the live one would
# be editing the machine's settings to check a message.

# make_prefs <file> <profile> [action] — a Terminal prefs plist shaped like the
# real one. Omit <action> for a profile that has no shellExitAction at all, which
# is how Terminal leaves a profile nobody has touched.
make_prefs() {
    local f="$1" profile="$2" action="${3:-}"
    rm -f "${f}"
    /usr/libexec/PlistBuddy -c "Add :\"Default Window Settings\" string ${profile}" "${f}" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :\"Window Settings\" dict" "${f}" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :\"Window Settings\":\"${profile}\" dict" "${f}" >/dev/null
    [ -z "${action}" ] || /usr/libexec/PlistBuddy \
        -c "Add :\"Window Settings\":\"${profile}\":shellExitAction integer ${action}" "${f}" >/dev/null
}

TEST_TERM_PROGRAM="Apple_Terminal"

# 1 — measured to mean "close the window, however the run ended": a .command
# exiting 0 and one exiting 3 both had their window closed under it. That makes
# it the DANGEROUS setting, not the good one — the obvious reading of the number
# is backwards, and a note that got this backwards would tell an operator their
# failures are safe on screen when they are not.
PREFS_ALWAYS="${WORK}/prefs-1.plist"
make_prefs "${PREFS_ALWAYS}" "Cut Profile" 1
TEST_TERMINAL_PREFS="${PREFS_ALWAYS}" run_launcher "${REQ_OK}"; rc=$?
check "shellExitAction=1 still cuts — it is a note, not a gate" "${rc}" "0"
check "shellExitAction=1 still reaches release.sh" "$(calls)" "cli --channel stable --dry-run"
check_contains "shellExitAction=1 warns that a failure would vanish" "$(log_text)" \
    "a FAILED cut would vanish off the screen"
check_contains "the profile is named, so the right one gets fixed" "$(log_text)" "'Cut Profile'"
check_contains "the note says where the setting lives" "$(log_text)" "When the shell exits"

# 2 — measured to mean "never close the window": a shell that exited 0 under it
# stayed. The operator gets a dead window after every cut, which is safe but
# needs saying or it looks like the launcher hung.
PREFS_STAY="${WORK}/prefs-2.plist"
make_prefs "${PREFS_STAY}" "Cut Profile" 2
TEST_TERMINAL_PREFS="${PREFS_STAY}" run_launcher "${REQ_OK}"; rc=$?
check "shellExitAction=2 still cuts" "${rc}" "0"
check_contains "shellExitAction=2 is reported" "$(log_text)" "never closes this window"

# Absent — a profile nobody has touched carries no key at all, and Terminal's own
# default is to leave the window. Reading the key is not enough; its absence is a
# branch of its own, worded as the absence it is.
PREFS_UNSET="${WORK}/prefs-unset.plist"
make_prefs "${PREFS_UNSET}" "Cut Profile"
TEST_TERMINAL_PREFS="${PREFS_UNSET}" run_launcher "${REQ_OK}"; rc=$?
check "no shellExitAction key still cuts" "${rc}" "0"
check_contains "an absent setting is reported as absent" "$(log_text)" \
    'has no "When the shell exits" setting'

# A value nobody measured. "Close if the shell exited cleanly" is in Terminal's
# menu but no profile on the machine this was written on used it, so its tag was
# never observed. An unmeasured value must be reported as unmeasured — sorting it
# into whichever branch looks plausible is how a note starts lying.
PREFS_ODD="${WORK}/prefs-9.plist"
make_prefs "${PREFS_ODD}" "Cut Profile" 9
TEST_TERMINAL_PREFS="${PREFS_ODD}" run_launcher "${REQ_OK}"; rc=$?
check "an unknown shellExitAction still cuts" "${rc}" "0"
check_contains "an unknown value is admitted, not guessed" "$(log_text)" \
    "something this launcher has not measured (shellExitAction=9)"

# A prefs file that is not there at all — Terminal never launched on this
# machine, or the path moved. Silence, and a cut that does not care.
TEST_TERMINAL_PREFS="${WORK}/no-such-prefs.plist" run_launcher "${REQ_OK}"; rc=$?
check "missing prefs file still cuts" "${rc}" "0"
check "missing prefs file says nothing" \
    "$(log_text | grep -c '^note: Terminal profile' | tr -d '[:space:]')" "0"

# The guard that keeps all of the above off a non-Terminal terminal. Driven the
# other way on purpose: if TERM_PROGRAM were ignored, the four cases above would
# be measuring a check that fires for everyone, and the note would appear in
# iTerm, in Ghostty and under script(1).
TEST_TERM_PROGRAM="ghostty" TEST_TERMINAL_PREFS="${PREFS_STAY}" run_launcher "${REQ_OK}"; rc=$?
check "not Apple_Terminal: no note" \
    "$(log_text | grep -c '^note: Terminal profile' | tr -d '[:space:]')" "0"
check "not Apple_Terminal: cuts anyway" "${rc}" "0"

unset TEST_TERM_PROGRAM TEST_TERMINAL_PREFS

# The property the whole check exists for. Under shellExitAction=1 a failed cut
# would be closed off the screen, so the launcher holds the window itself —
# without being asked, because nobody asks in advance for the run that fails.
# Under a profile that keeps the window there is nothing to hold and it must not.
export RELEASE_STUB_RC=5
TEST_TERMINAL_PREFS="${PREFS_ALWAYS}" run_launcher "${REQ_OK}"; rc=$?
check_refusal "failed cut under a closing profile" "${rc}"
check "failed cut under a closing profile keeps its code" "$(sentinel_code)" "5"
TEST_TERMINAL_PREFS="${PREFS_STAY}" run_launcher "${REQ_OK}"; rc=$?
check_refusal "failed cut under a keeping profile" "${rc}"
unset RELEASE_STUB_RC
# Whether the hold actually happened is not observable from the log — it prints
# to the terminal, and the harness answers it instantly with EOF. What IS pinned
# is that it is reached only on the closing profile and only on a failure, and
# that neither case can alter the exit status or the last line of the log.
# shellcheck disable=SC2016  # $rc and $WINDOW_CLOSES_REGARDLESS are the launcher's
check "the failure hold is gated on both the code and the profile" \
    "$(grep -c 'elif \[ "\$rc" -ne 0 \] && \[ "\${WINDOW_CLOSES_REGARDLESS}" = "1" \]; then' "${LAUNCHER}")" "1"

echo "--- KEEP_WINDOW -------------------------------------------------------"

# The sentinel and the hold are ordered, and the order is the point: the log is
# finished before anything blocks, so an agent watching for RELEASE-EXIT: is
# never left waiting on an operator who has walked away from a held window.
REQ_KEEP="${WORK}/req-keep"
printf 'COMPONENTS="cli"\nFLAGS="--dry-run"\nKEEP_WINDOW=1\n' > "${REQ_KEEP}"
run_launcher "${REQ_KEEP}"; rc=$?
check "KEEP_WINDOW=1 still cuts (rc)" "${rc}" "0"
check "KEEP_WINDOW=1 still cuts (component)" "$(calls)" "cli --channel stable --dry-run"
check "KEEP_WINDOW=1: exactly one RELEASE-EXIT line" "$(sentinel_count)" "1"
check "KEEP_WINDOW=1: sentinel is still the LAST line of the log" "$(sentinel_is_last)" "RELEASE-EXIT"
check_contains "KEEP_WINDOW=1 is echoed back" "$(log_text)" \
    "window: KEEP_WINDOW=1 — held at the end until you press Return"

# The hold prints to the terminal, not through say(). If it ever went to the log
# the check above would fail — this asserts the other half: the prompt is not in
# the file, so the file still ends where a watcher expects it to.
check "the hold prompt never reaches the log" \
    "$(log_text | grep -c 'let this window close' | tr -d '[:space:]')" "0"

# Left unset, nothing is held and the default is announced with the way out.
run_launcher "${REQ_OK}"; rc=$?
check "default run: exits 0" "${rc}" "0"
check "default run: sentinel is the last line" "$(sentinel_is_last)" "RELEASE-EXIT"
check_contains "default run: the opt-out is advertised" "$(log_text)" \
    "KEEP_WINDOW=1 holds it open regardless"

# The hold must not swallow the exit code — a failed cut that reported 0 because
# somebody pressed Return is the worst outcome this file can produce.
export RELEASE_STUB_RC=7
run_launcher "${REQ_KEEP}"; rc=$?
unset RELEASE_STUB_RC
check_refusal "KEEP_WINDOW=1 on a failed cut" "${rc}"
check "KEEP_WINDOW=1 on a failed cut: the sentinel still says 7" "$(sentinel_code)" "7"

echo "--- lock --------------------------------------------------------------"

# Two `open`s — an agent racing an operator, or a double-click — would otherwise
# interleave into one log and race each other's marker commits and pushes.
mkdir "${REPO}/.release.lock"
run_launcher "${REQ_OK}"; rc=$?
check_refusal "second run while a lock exists" "${rc}"
check_contains "the lock is named" "$(log_text)" ".release.lock"
check "locked-out run cuts nothing" "$(calls)" ""
# And it must not clear the lock on its way out: the trap removes only a lock
# THIS run took, or a refusal would hand the directory to a third `open` while
# the first cut is still live.
check "locked-out run leaves the lock alone" \
    "$([ -d "${REPO}/.release.lock" ] && echo yes || echo no)" "yes"
rmdir "${REPO}/.release.lock"

# Negative control: with the lock gone the same request runs, so the case above
# is measuring the lock and not some other refusal.
run_launcher "${REQ_OK}"; rc=$?
check "same request runs once the lock is gone (rc)" "${rc}" "0"
check "the run releases its own lock" \
    "$([ -d "${REPO}/.release.lock" ] && echo yes || echo no)" "no"

echo "--- release.sh failure ------------------------------------------------"

# A component that fails must stop the batch, propagate its own exit code all
# the way to the sentinel, and say plainly that what already cut is published.
export RELEASE_STUB_RC=3
run_launcher "${REQ_TWO}"; rc=$?
unset RELEASE_STUB_RC
check "failing component propagates its exit code" "${rc}" "3"
check "failing component: exactly one RELEASE-EXIT line" "$(sentinel_count)" "1"
check "failing component: sentinel carries the exit code" "$(sentinel_code)" "3"
check "failing component stops the batch" "$(calls)" "cli --channel stable --dry-run"
check_contains "failure warns that earlier cuts are published" "$(log_text)" "are PUBLISHED"

echo "--- log rotation ------------------------------------------------------"

# Exactly one run per log: a refusal that truncated the log in place would
# destroy the record of the last real cut, which is the only account of what was
# published.
run_launcher "${REQ_OK}" >/dev/null 2>&1
cp "${LOG}" "${WORK}/first.log"
RELEASE_ENV="${ENV_FILE}" RELEASE_REQUEST="${REQ_ALL}" RELEASE_LOG="${LOG}" \
    PATH="${STUBS}:/usr/bin:/bin" \
    /usr/bin/script -q /dev/null /bin/bash "${REPO}/tools/release.command" \
    </dev/null >/dev/null 2>&1
check "the previous log is rotated, not overwritten" \
    "$(cmp -s "${LOG}.prev" "${WORK}/first.log" && echo same || echo different)" "same"
check "the new log holds only the new run" "$(sentinel_count)" "1"

echo
# NOT COVERED HERE: close_own_window's Apple Event. It needs a real Terminal
# window — a pty from script(1) is not one — and it talks to /usr/bin/osascript
# by absolute path, so PATH stubbing cannot reach it any more than it can reach
# git. What IS covered above is everything the rest of the launcher depends on:
# the exit code survives it, the log is finished before it, and the opt-out is
# read. The close itself was measured by hand against real Terminal windows;
# what that measurement found is written up in the PR, and it is not flattering.
#
# NOT COVERED HERE: push_marker/tree_state/unpushed_count. They run only on a
# non-dry cut, they talk to /usr/bin/git by absolute path (so PATH stubbing
# cannot reach them), and exercising them means a real repository with a real
# remote — a push, which no unit test may perform. The branch / clean-tree /
# in-sync invariants they re-assert at the moment of the push are covered as
# predicates by tools/release_origin.test.sh.
if [ "${fail}" = 0 ]; then echo "ALL OK"; else echo "TESTS FAILED"; exit 1; fi
