#!/bin/sh
# tools/prefix-gate-drift.test.sh — pins two unrelated duplicated-block
# families that happen to live in the same four files: the root-only PREFIX
# guard, and (since the "install ends running" work) the start_unit_darwin /
# start_unit_linux service-start helpers. A fix applied to one inner/
# installer and not its sibling(s) fails the build.
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
# THE START-UNIT HELPERS LIVE IN THE SAME FOUR FILES — VERIFIED, NOT
# ASSUMED. agent/install.sh and cli/install.sh are unprivileged per-user
# installs with no service unit at all, so they carry no start_unit_darwin /
# start_unit_linux either; grepping both for the function names before this
# suite was written turned up nothing. Because the file set is identical to
# the PREFIX guard's, ONE file-count tripwire (below) gates both families —
# a second tripwire asserting "4" again would test nothing a code reviewer
# couldn't already see is redundant. What the two families do NOT share is
# the shape of the comparison (pairwise vs. all-four), so each still gets
# its own "comparisons actually ran" tripwire.
#
# FOUR CLAIMS ARE PINNED, IN TWO GROUPS, BECAUSE THEY ARE DIFFERENT COPY
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
#   3. start_unit_darwin() is byte-identical across ALL FOUR files, same
#      shape as claim 1: it takes a label/plist pair as arguments, so it
#      carries no component-specific text and any difference is drift.
#      WHAT DOES differ between the four — elevation — is read from a
#      variable the body expands, NOT patched into the body and NOT wrapped
#      at the call site: each file sets $_RUNROOT just above the helpers
#      (empty in the root-only inner/edge/install.sh, run_root in
#      inner/gateway/install.sh, elevate in both updater.install.sh), and
#      the body spells every launchctl call `$_RUNROOT launchctl …`. A call
#      site cannot wrap what the helper runs internally, which is why the
#      prefix is inside the pinned body and the pin still holds.
#
#   4. start_unit_linux() is byte-identical across ALL FOUR files, same
#      reasoning as claim 3, with a second seam for the same reason:
#      $_SYSTEMCTL, so the two updater.install.sh files reach systemctl
#      through the $SYSTEMCTL test seam they declare and still use
#      everywhere else.
#
# THE ANCHOR IS STRUCTURAL, NOT ONE COMPONENT'S PRONE. `normalize_dir() {` /
# `start_unit_darwin() {` / `start_unit_linux() {`, each closed by a `}` /
# `fi` at column 0, and `if [ -n "${PREFIX:-}" ]; then` / `fi` are the exact
# same literal text, unindented, in all four files — verified before this
# suite was written, not assumed. The PREFIX anchors are the SAME two
# anchors gateway's own prefix_gate_drift_test.go slices on, ported (not
# reinvented) so the two pins agree on what "the guard" is. The start_unit_*
# anchors have no Go-side counterpart to port from — they are new to this
# suite (Task 5 of the "install ends running" plan).
#
# PORT NOTE: gateway's sliceBlock returns the lines from the first line
# EQUAL to the start marker through the first following line EQUAL to the
# end marker (exact line match — its own doc-comment says "trimmed form",
# but the Go source does not trim; ported here against the code, not the
# comment, since a paraphrase drifting from its own implementation is
# exactly the failure class this project keeps hitting). All anchors used
# here sit at column 0 in all four files, so exact-match and trimmed-match
# agree — this port is faithful either way.
#
# BASELINE, VERIFIED BEFORE THIS SUITE WAS WRITTEN: today all four guards and
# all four start_unit_* pairs are drift-free (confirmed with md5 across the
# four files before this suite existed). normalize_dir() and both
# start_unit_* helpers are byte-identical across all four; the PREFIX gate
# block is byte-identical within both pairs. This suite locks a
# verified-good state — it does not go looking for a bug that is believed to
# exist.
#
# A GLOB MATCHING ZERO OR ONE FILE PASSES VACUOUSLY. Three independent
# tripwires guard against that: the file count (must be exactly 4, shared by
# both families — see above) is asserted BEFORE any comparison runs; the
# number of PREFIX-guard pairs actually compared (must be exactly 2) is
# asserted after claim 2; and the number of start_unit_* comparisons
# actually made (must be exactly 3 per helper — four files, one baseline,
# three compared against it) is asserted after claims 3 and 4. A future
# refactor that silently empties the file list fails the first; one that
# leaves the file list correct but breaks a comparison loop itself (so it
# runs zero times) still fails whichever of the other two covers that loop.
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

# extract_start_unit_darwin <file>
extract_start_unit_darwin() {
    _f="$1"
    _out="$(extract_block "$_f" 'start_unit_darwin() {' '}')"; _rc=$?
    case "$_rc" in
    0) ;;
    3) fatal "$_f: no line 'start_unit_darwin() {' — the helper was renamed or removed; the copies can no longer be compared" ;;
    *) fatal "$_f: start_unit_darwin() { is never closed by a line reading '}'" ;;
    esac
    printf '%s' "$_out"
}

# extract_start_unit_linux <file>
extract_start_unit_linux() {
    _f="$1"
    _out="$(extract_block "$_f" 'start_unit_linux() {' '}')"; _rc=$?
    case "$_rc" in
    0) ;;
    3) fatal "$_f: no line 'start_unit_linux() {' — the helper was renamed or removed; the copies can no longer be compared" ;;
    *) fatal "$_f: start_unit_linux() { is never closed by a line reading '}'" ;;
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

# ---------------------------------------------------------------------------
# Claim 3: start_unit_darwin() is byte-identical across all four files.
# Claim 4: start_unit_linux() is byte-identical across all four files.
#
# Same shape as Claim 1 (all-four, not pairwise): the helper takes its label
# / plist / unit as arguments and carries no component-specific text, so
# there is no legitimate cross-component difference the way the PREFIX
# guard's operator-facing message has one.
# ---------------------------------------------------------------------------
_first_sud=""
_first_sud_f=""
_first_sul=""
_first_sul_f=""
DARWIN_COMPARED=0
LINUX_COMPARED=0
for _c in $COMPONENTS; do
    for _kind in install.sh updater.install.sh; do
        _f="inner/$_c/$_kind"

        _block="$(extract_start_unit_darwin "$HERE/$_f")"
        for _want in '$_RUNROOT launchctl bootstrap system' '$_RUNROOT launchctl enable' '$_RUNROOT launchctl kickstart' '$_RUNROOT launchctl print'; do
            case "$_block" in
            *"$_want"*) ;;
            *) fatal "$_f: the extracted start_unit_darwin no longer contains [$_want] — the comparison is vacuous" ;;
            esac
        done
        if [ -z "$_first_sud" ]; then
            _first_sud="$_block"
            _first_sud_f="$_f"
        else
            CASES=$((CASES + 1))
            if [ "$_block" != "$_first_sud" ]; then
                fail "start_unit_darwin() in $_f differs from $_first_sud_f"
            fi
            DARWIN_COMPARED=$((DARWIN_COMPARED + 1))
        fi

        _block="$(extract_start_unit_linux "$HERE/$_f")"
        for _want in '$_RUNROOT "$_SYSTEMCTL" enable --now' '$_RUNROOT "$_SYSTEMCTL" restart' '$_RUNROOT "$_SYSTEMCTL" is-active'; do
            case "$_block" in
            *"$_want"*) ;;
            *) fatal "$_f: the extracted start_unit_linux no longer contains [$_want] — the comparison is vacuous" ;;
            esac
        done
        if [ -z "$_first_sul" ]; then
            _first_sul="$_block"
            _first_sul_f="$_f"
        else
            CASES=$((CASES + 1))
            if [ "$_block" != "$_first_sul" ]; then
                fail "start_unit_linux() in $_f differs from $_first_sul_f"
            fi
            LINUX_COMPARED=$((LINUX_COMPARED + 1))
        fi
    done
done

# ---------------------------------------------------------------------------
# Tripwire 3: the number of start_unit_* comparisons actually made, one
# counter per helper. Independent of Tripwire 1 (file count) for the same
# reason Tripwire 2 is: a loop that runs zero times leaves the file list
# untouched and would otherwise pass silently. Four files, one baseline each
# → three comparisons expected per helper.
# ---------------------------------------------------------------------------
assert_eq "$DARWIN_COMPARED" "3" "expected exactly 3 start_unit_darwin() comparisons (4 files, 1 baseline)"
assert_eq "$LINUX_COMPARED" "3" "expected exactly 3 start_unit_linux() comparisons (4 files, 1 baseline)"

echo "cases: $CASES  failed: $FAILED"
if [ "$FAILED" = 0 ]; then echo "ALL OK"; else echo "TESTS FAILED"; exit 1; fi
