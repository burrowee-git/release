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
check "cli gateway: both cut, in order, with FLAGS" "$(calls)" "cli --dry-run
gateway --dry-run"
check_contains "cli gateway: --dry-run is announced" "$(log_text)" "no marker will be pushed"

# Every accepted name, one run each, so the list cannot rot to a subset.
for comp in cli gateway edge agent relay; do
    REQ_ONE="${WORK}/req-${comp}"
    printf 'COMPONENTS="%s"\nFLAGS="--dry-run"\n' "${comp}" > "${REQ_ONE}"
    run_launcher "${REQ_ONE}"; rc=$?
    check "component '${comp}' is accepted (rc)" "${rc}" "0"
    check "component '${comp}' reaches release.sh" "$(calls)" "${comp} --dry-run"
done

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
check "failing component stops the batch" "$(calls)" "cli --dry-run"
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
# NOT COVERED HERE: push_marker/tree_state/unpushed_count. They run only on a
# non-dry cut, they talk to /usr/bin/git by absolute path (so PATH stubbing
# cannot reach them), and exercising them means a real repository with a real
# remote — a push, which no unit test may perform. The branch / clean-tree /
# in-sync invariants they re-assert at the moment of the push are covered as
# predicates by tools/release_origin.test.sh.
if [ "${fail}" = 0 ]; then echo "ALL OK"; else echo "TESTS FAILED"; exit 1; fi
