#!/bin/sh
# tools/prefix-gate-drift.test.sh — pins the root-only PREFIX guard so a fix
# applied to one inner/ installer and not its sibling fails the build.
#
#     sh tools/prefix-gate-drift.test.sh          # this shell
#     dash tools/prefix-gate-drift.test.sh        # and this one, always
#
# WHY THIS SUITE EXISTS AND WHY IT LIVES HERE, NOT IN gateway/. Gateway's own
# internal/updatescript/prefix_gate_drift_test.go pins the same guard, but its
# `prefixGateScripts` are repo-root-relative paths INSIDE THE GATEWAY REPO
# (update.sh, migrations/upgrade.sh) — it has no way to see a release-repo
# file. inner/edge/updater.install.sh and inner/gateway/updater.install.sh
# ship a byte-identical copy of the same guard and were never covered by
# anything until this suite.
#
# THE SCOPE IS FOUR FILES, NOT SIX. inner/agent/install.sh and
# inner/cli/install.sh carry NO PREFIX guard at all — no normalize_dir(), no
# root-only refusal. Both are plain per-user, unprivileged installs
# (default $HOME/.local) that honour any PREFIX unconditionally, unlike
# edge/gateway, which are root-owned services with exactly one true
# destination the guard protects. Globbing inner/*/install.sh and comparing
# every hit would abort on the very first file (agent/install.sh,
# alphabetically first) for the wrong reason — "no guard here" is not
# drift — so the four files this suite actually reads are named explicitly:
#
#   inner/edge/install.sh            inner/edge/updater.install.sh
#   inner/gateway/install.sh         inner/gateway/updater.install.sh
#
# TWO CLAIMS ARE PINNED, NOT ONE, BECAUSE THEY ARE DIFFERENT COPY
# RELATIONSHIPS:
#
#   1. normalize_dir() is byte-identical across ALL FOUR files. It is the
#      shared primitive with no component-specific content, so ANY
#      difference there — in either component, in either script — is drift.
#
#   2. The gate block (`if [ -n "${PREFIX:-}" ]; then` … `fi`) is
#      byte-identical WITHIN each component pair only: edge/install.sh
#      against edge/updater.install.sh, and gateway/install.sh against
#      gateway/updater.install.sh. edge's guard and gateway's guard are NOT
#      compared to each other — each names its own component and
#      destination in its operator-facing messages ("as of edge 0.2.0 …" vs
#      "as of gateway 0.2.0 …"), and that difference is correct, not drift.
#      Only the copy relationship that actually exists (an installer and its
#      updater sibling, same component) is asserted.
#
# THE ANCHOR IS STRUCTURAL, NOT ONE COMPONENT'S PRONE. `normalize_dir() {` /
# `}` and `if [ -n "${PREFIX:-}" ]; then` / `fi` are the exact same literal
# text, unindented, in all four files — verified before this suite was
# written, not assumed. These are the SAME two anchors gateway's own
# prefix_gate_drift_test.go slices on, ported (not reinvented) so the two
# pins agree on what "the guard" is.
#
# PORT NOTE: gateway's sliceBlock returns the lines from the first line
# EQUAL to the start marker through the first following line EQUAL to the
# end marker (exact line match — its own doc-comment says "trimmed form",
# but the Go source does not trim; ported here against the code, not the
# comment, since a paraphrase drifting from its own implementation is
# exactly the failure class this project keeps hitting). Both anchors used
# here sit at column 0 in all four files, so exact-match and trimmed-match
# agree — this port is faithful either way.
#
# BASELINE, VERIFIED BEFORE THIS SUITE WAS WRITTEN: today all four guards are
# drift-free. normalize_dir() is byte-identical across all four; the gate
# block is byte-identical within both pairs. This suite locks a verified-good
# state — it does not go looking for a bug that is believed to exist.
#
# A GLOB MATCHING ZERO OR ONE FILE PASSES VACUOUSLY. Two independent
# tripwires guard against that: the file count (must be exactly 4) is
# asserted BEFORE any comparison runs, and the number of component pairs
# actually compared (must be exactly 2) is asserted AFTER — so a future
# refactor that silently empties the file list fails the first, and one that
# leaves the file list correct but breaks the comparison loop itself (so it
# runs zero times) still fails the second.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"

FAILED=0
CASES=0
fail() { FAILED=$((FAILED + 1)); echo "FAIL: $*" >&2; }
assert_eq() {
    CASES=$((CASES + 1))
    if [ "$1" != "$2" ]; then fail "$3: want [$2] got [$1]"; fi
}
assert_contains() {
    CASES=$((CASES + 1))
    case "$1" in
    *"$2"*) ;;
    *) fail "$3: does not contain [$2]
--- got ---
$1
--- end ---" ;;
    esac
}
fatal() {
    # fatal <msg> — a missing/unclosed anchor means the pin cannot compare
    # anything; this aborts the whole run rather than reporting a false pass,
    # the same way gateway's sliceBlock calls t.Fatalf rather than t.Errorf.
    echo "FATAL: $*" >&2
    exit 1
}

# extract_block <file> <start-literal> <end-literal> — ports gateway's
# sliceBlock: the lines from the first line EQUAL to start-literal through
# the first following line EQUAL to end-literal, inclusive. Exit 3 if start
# is never found, exit 4 if start is found but never closed.
extract_block() {
    awk -v start="$2" -v end="$3" '
        BEGIN { found = 0; closed = 0 }
        !found && $0 == start { found = 1 }
        found { print; if ($0 == end) { closed = 1; exit } }
        END { if (!found) exit 3; if (!closed) exit 4 }
    ' "$1"
}

# extract_normalize_dir <file>
extract_normalize_dir() {
    _f="$1"
    _out="$(extract_block "$_f" 'normalize_dir() {' '}')"; _rc=$?
    case "$_rc" in
    0) ;;
    3) fatal "$_f: no line 'normalize_dir() {' — the helper was renamed or removed; the copies can no longer be compared" ;;
    *) fatal "$_f: normalize_dir() { is never closed by a line reading '}'" ;;
    esac
    printf '%s' "$_out"
}

# extract_prefix_guard <file>
extract_prefix_guard() {
    _f="$1"
    _out="$(extract_block "$_f" 'if [ -n "${PREFIX:-}" ]; then' 'fi')"; _rc=$?
    case "$_rc" in
    0) ;;
    3) fatal "$_f: no line 'if [ -n \"\${PREFIX:-}\" ]; then' — the guard was renamed or removed; the copies can no longer be compared" ;;
    *) fatal "$_f: the guard is never closed by a line reading 'fi'" ;;
    esac
    printf '%s' "$_out"
}

# ---------------------------------------------------------------------------
# Tripwire 1: the file count. Named explicitly (see header) rather than
# inner/*/install.sh, because that glob also matches inner/agent/install.sh
# and inner/cli/install.sh, which carry no guard at all.
# ---------------------------------------------------------------------------
COMPONENTS="edge gateway"
FILE_COUNT=0
for _c in $COMPONENTS; do
    for _kind in install.sh updater.install.sh; do
        _f="inner/$_c/$_kind"
        [ -f "$HERE/$_f" ] && FILE_COUNT=$((FILE_COUNT + 1))
    done
done
assert_eq "$FILE_COUNT" "4" "expected exactly 4 guard-bearing files (edge+gateway × install.sh+updater.install.sh)"
if [ "$FILE_COUNT" != 4 ]; then
    fail "aborting: the file count tripwire failed, so no comparison can be trusted"
    echo "cases: $CASES  failed: $FAILED"; echo "TESTS FAILED"; exit 1
fi

# ---------------------------------------------------------------------------
# Claim 1: normalize_dir() is byte-identical across all four files.
# ---------------------------------------------------------------------------
_first_nd=""
_first_nd_f=""
for _c in $COMPONENTS; do
    for _kind in install.sh updater.install.sh; do
        _f="inner/$_c/$_kind"
        _block="$(extract_normalize_dir "$HERE/$_f")"
        for _want in "printf '%s'" "sed -e"; do
            case "$_block" in
            *"$_want"*) ;;
            *) fatal "$_f: the extracted normalize_dir no longer contains [$_want] — the comparison is vacuous" ;;
            esac
        done
        if [ -z "$_first_nd" ]; then
            _first_nd="$_block"
            _first_nd_f="$_f"
            continue
        fi
        CASES=$((CASES + 1))
        if [ "$_block" != "$_first_nd" ]; then
            fail "normalize_dir() in $_f differs from $_first_nd_f"
        fi
    done
done

# ---------------------------------------------------------------------------
# Claim 2: the gate block is byte-identical WITHIN each component pair only.
# Cross-component is deliberately never compared (see header).
# ---------------------------------------------------------------------------
PAIRS_COMPARED=0
for _c in $COMPONENTS; do
    _install="inner/$_c/install.sh"
    _updater="inner/$_c/updater.install.sh"
    _g_install="$(extract_prefix_guard "$HERE/$_install")"
    _g_updater="$(extract_prefix_guard "$HERE/$_updater")"
    for _want in "normalize_dir" "unset PREFIX" "exit 1"; do
        case "$_g_install" in
        *"$_want"*) ;;
        *) fatal "$_install: the extracted gate no longer contains [$_want] — the comparison is vacuous" ;;
        esac
    done
    CASES=$((CASES + 1))
    if [ "$_g_install" != "$_g_updater" ]; then
        fail "PREFIX guard in $_updater differs from $_install"
    fi
    PAIRS_COMPARED=$((PAIRS_COMPARED + 1))
done

# ---------------------------------------------------------------------------
# Tripwire 2: the number of pairs actually compared. Independent of Tripwire
# 1 — it catches a comparison loop that stopped running, not just a file
# list that came up short.
# ---------------------------------------------------------------------------
assert_eq "$PAIRS_COMPARED" "2" "expected exactly 2 component pairs (edge, gateway) to be compared"

echo "cases: $CASES  failed: $FAILED"
if [ "$FAILED" = 0 ]; then echo "ALL OK"; else echo "TESTS FAILED"; exit 1; fi
