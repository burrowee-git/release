#!/usr/bin/env bash
# batch.test.sh — unit tests for tools/batch.sh.
#
# `release.sh all` cuts cli, gateway, edge, agent in order under `set -e`. When
# one of them fails the script dies where it stands and the components queued
# behind it never run — with nothing in the output saying so. On 2026-08-18
# that read as one failure; it was one success and two silent omissions.
#
# These tests drive batch.sh through a generated harness that reproduces
# release.sh's exact shape — `set -euo pipefail`, an EXIT/INT/TERM trap, a bare
# (unwrapped) call to the per-component function — because that shape is the
# thing under test. A runner called inside `if` or `||` would have `set -e`
# suspended for its whole body, which is precisely the semantics release.sh
# must NOT lose, so the harness never does that.
#
# The runner is faked: no part of the release path runs, nothing is built,
# signed, notarized or published.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
check_lacks() { # check_lacks <label> <haystack> <needle>
    case "$2" in
        *"$3"*) echo "FAIL: $1 — '$2' unexpectedly contains '$3'"; fail=1 ;;
        *) echo "ok: $1" ;;
    esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# harness <how-gateway-fails> — writes a script shaped like release.sh's tail
# and runs it over (cli gateway edge). Leaves the combined output in
# HARNESS_OUT and the exit status in HARNESS_RC.
#
# Deliberately NOT `out="$(harness …)"`: a command substitution is a subshell,
# so a status assigned inside it never reaches the caller. Both results come
# back through globals set in this shell instead.
#
# <how-gateway-fails>: ok | return | exit3 | seterr
#   return  — the runner returns 1 (release.sh's `|| return 1` style)
#   exit3   — the runner calls `exit 3` (release.sh does this in several
#             failure paths, e.g. "unknown component"); an EXIT trap is the
#             ONLY thing that can still report in that case
#   seterr  — the runner runs an unchecked failing command under `set -e`
harness() {
    local mode="$1" script="${WORK}/harness-$1.sh"
    cat > "${script}" <<HARNESS
set -euo pipefail
source "${HERE}/batch.sh"

# Stand-ins for release.sh's real EXIT handlers, to prove the summary composes
# with them rather than replacing them.
shred_key() { echo "(shred_key ran)"; }
trap 'shred_key; batch_summary' EXIT INT TERM

do_release() {
    local comp="\$1"
    echo "cutting \${comp}"
    if [ "\${comp}" = gateway ]; then
        case "${mode}" in
            return) return 1 ;;
            exit3)  exit 3 ;;
            seterr) /usr/bin/false ;;
        esac
    fi
    echo "released \${comp}"
}

COMPONENTS=(cli gateway edge)
batch_begin "\${COMPONENTS[@]}"
for comp in "\${COMPONENTS[@]}"; do
    batch_start "\${comp}"
    do_release "\${comp}"
    batch_ok "\${comp}"
done
HARNESS
    bash "${script}" > "${WORK}/harness-$1.out" 2>&1
    HARNESS_RC=$?          # read directly off bash, NOT off a pipeline
    HARNESS_OUT="$(cat "${WORK}/harness-$1.out")"
}

# ── check 1: the whole batch succeeds ───────────────────────────────────────
# First, because every failure case below is a variation on a fixture that is
# proven to pass unmodified.
harness ok;     out="${HARNESS_OUT}"; rc="${HARNESS_RC}"
check "all-ok: exits 0" "${rc}" "0"
check_contains "all-ok: summary reports every component released" "${out}" "released: cli gateway edge"
check_lacks "all-ok: says nothing about components that never ran" "${out}" "never ran"

# ── check 2: a mid-batch `return 1` ─────────────────────────────────────────
harness return; out="${HARNESS_OUT}"; rc="${HARNESS_RC}"
[ "${rc}" -ne 0 ] && rr=nonzero || rr=zero
check "return-1: exits non-zero" "${rr}" "nonzero"
check_contains "return-1: names what did succeed" "${out}" "released: cli"
check_contains "return-1: names the component that FAILED" "${out}" "failed: gateway"
check_contains "return-1: names the component that NEVER RAN" "${out}" "never ran: edge"
check_contains "return-1: the pre-existing EXIT handler still runs" "${out}" "(shred_key ran)"
check_lacks "return-1: edge was never attempted" "${out}" "cutting edge"

# ── check 3: a mid-batch `exit 3` ───────────────────────────────────────────
# release.sh's failure paths call `exit` far more often than they `return`. An
# `if runner; then` design cannot report here at all — the shell is already
# gone — which is why the summary hangs off the EXIT trap.
harness exit3;  out="${HARNESS_OUT}"; rc="${HARNESS_RC}"
check "exit-3: the runner's own status is preserved, not clobbered by the trap" "${rc}" "3"
check_contains "exit-3: names the component that FAILED" "${out}" "failed: gateway"
check_contains "exit-3: names the component that NEVER RAN" "${out}" "never ran: edge"

# ── check 4: a mid-batch `set -e` death ─────────────────────────────────────
harness seterr; out="${HARNESS_OUT}"; rc="${HARNESS_RC}"
[ "${rc}" -ne 0 ] && rr=nonzero || rr=zero
check "set-e death: exits non-zero" "${rr}" "nonzero"
check_contains "set-e death: names the component that FAILED" "${out}" "failed: gateway"
check_contains "set-e death: names the component that NEVER RAN" "${out}" "never ran: edge"

# ── check 5: no batch, no noise ─────────────────────────────────────────────
# release.sh's EXIT trap is armed long before the component loop; a pre-flight
# failure must not print an empty summary.
cat > "${WORK}/noloop.sh" <<NOLOOP
set -euo pipefail
source "${HERE}/batch.sh"
trap 'batch_summary' EXIT INT TERM
echo "✗ required tool not found: jq"
exit 1
NOLOOP
out="$(bash "${WORK}/noloop.sh" 2>&1)"; rc=$?
check "no-batch: status untouched" "${rc}" "1"
check_lacks "no-batch: prints no summary" "${out}" "batch"

# ── check 6: release.sh actually wires the loop up ──────────────────────────
# The harness proves the mechanism; this proves the caller uses it. Same
# structural-assertion pattern as cmd/rkit's TestReleasePublishesEveryRenderedArtifact.
RELEASE_SH="${HERE}/release.sh"
check "release.sh: the component loop opens a batch" \
    "$(grep -c '^batch_begin "\${COMPONENTS\[@\]}"' "${RELEASE_SH}" || true)" "1"
check "release.sh: the loop marks each component started" \
    "$(grep -c '^[[:space:]]*batch_start "\${comp}"' "${RELEASE_SH}" || true)" "1"
check "release.sh: the loop marks each component finished" \
    "$(grep -c '^[[:space:]]*batch_ok "\${comp}"' "${RELEASE_SH}" || true)" "1"
check_contains "release.sh: the EXIT trap reports the batch" \
    "$(grep "^trap .*EXIT INT TERM" "${RELEASE_SH}" || true)" "batch_summary"
check_contains "release.sh: the EXIT trap still shreds the key and reverts the dispatcher" \
    "$(grep "batch_summary' EXIT INT TERM" "${RELEASE_SH}" || true)" "shred_key; revert_dispatcher_version"

echo
if [ "${fail}" = 0 ]; then echo "ALL BATCH CHECKS PASSED"; else echo "BATCH CHECKS FAILED"; fi
exit "${fail}"
