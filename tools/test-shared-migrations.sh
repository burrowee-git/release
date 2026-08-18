#!/bin/sh
# tools/test-shared-migrations.sh — the suite for the SHARED migration ladder
# (inner/_shared/migrations/): the runner, the sweep library and the 0.2.0 rung
# that edge and cli both take.
#
#     sh tools/test-shared-migrations.sh          # this shell
#     dash tools/test-shared-migrations.sh        # and this one, always
#
# RUN IT UNDER dash AS WELL AS bash. /bin/sh is dash on every Debian-family
# host and bash 3.2 on macOS, and the difference is not academic here: a fatal
# `/dev/tty` redirection bug shipped undetected in two burrowee installers this
# month because the suite only ever ran under the developer's bash.
#
# EVERY PATH IS A FIXTURE UNDER $TMPDIR. Nothing here may resolve to a real
# $HOME/.local/bin, /usr/local/bin, /etc/systemd/system or /Library/
# LaunchDaemons — the machines this runs on carry live burrowee installs in
# exactly those places, and the thing under test deletes files.
#
# THE FIXTURE BINARIES ARE REAL, COMPILED, STAMPED Go BINARIES, not shell
# stubs. The sweep decides ownership by reading the module path the Go
# toolchain stamps into a binary's build-info blob. A shell stub carrying the
# literal string proves the predicate matches a string, which was never in
# doubt; what has to be provable is that a REAL binary that is NOT ours is left
# alone, and only a real foreign Go binary can show that. `ours.bin` is built
# from a module named github.com/burrowee-git/edge, `foreign.bin` from
# example.com/operator/tools — same toolchain, same flags, different module.
# Without both, a mutation that deletes the ownership check survives, because
# right and wrong produce identical state.
set -u

SUITE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# SHARED_MIGRATIONS_DIR is the MUTATION seam: tools/test-shared-migrations-mutants.sh
# points this at a deliberately broken copy of the ladder and requires this suite
# to redden. A suite with no way to be pointed at a mutant can only be trusted to
# the extent someone once read it.
SHARED="${SHARED_MIGRATIONS_DIR:-$SUITE_DIR/inner/_shared/migrations}"

FAILED=0
CASES=0

fail() {
    FAILED=$((FAILED + 1))
    echo "FAIL: $*" >&2
}
assert_gone() {
    CASES=$((CASES + 1))
    if [ -e "$1" ]; then fail "$2 ($1 still exists)"; fi
}
assert_present() {
    CASES=$((CASES + 1))
    if [ ! -e "$1" ]; then fail "$2 ($1 is gone)"; fi
}
assert_eq() {
    CASES=$((CASES + 1))
    if [ "$1" != "$2" ]; then fail "$3: want [$2] got [$1]"; fi
}
assert_contains() {
    CASES=$((CASES + 1))
    case "$1" in
    *"$2"*) ;;
    *) fail "$3: output does not contain [$2]
--- output ---
$1
--- end ---" ;;
    esac
}
# assert_lacks is not assert_contains inverted for the sake of symmetry: the
# shell hint has to be ABSENT on a run that removed nothing, and "the wrong
# branch was printed" is a claim only an absence can make. Written as its own
# helper so the failure message still shows the output, which is the whole
# reason the negative case is hard to debug otherwise.
assert_lacks() {
    CASES=$((CASES + 1))
    case "$1" in
    *"$2"*) fail "$3: output should not contain [$2]
--- output ---
$1
--- end ---" ;;
    esac
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
# TERM/INT/HUP as well as EXIT: a bare `trap … EXIT` does not fire when the
# shell is signalled, and this suite leaves multi-megabyte Go binaries behind.

BINFIX="$TMP/binfix"
mkdir -p "$BINFIX/ours/cmd/x" "$BINFIX/foreign/cmd/x"
cat > "$BINFIX/ours/go.mod" <<'EOF'
module github.com/burrowee-git/edge

go 1.21
EOF
cat > "$BINFIX/foreign/go.mod" <<'EOF'
module example.com/operator/tools

go 1.21
EOF
printf 'package main\n\nfunc main() { println("x") }\n' > "$BINFIX/ours/cmd/x/main.go"
printf 'package main\n\nfunc main() { println("x") }\n' > "$BINFIX/foreign/cmd/x/main.go"

if ! command -v go >/dev/null 2>&1; then
    echo "FAIL: go is not on PATH — this suite's whole ownership claim rests on" >&2
    echo "      real stamped binaries and it must not degrade to shell stubs." >&2
    exit 1
fi
( cd "$BINFIX/ours" && GOFLAGS=-mod=mod go build -trimpath -ldflags '-s -w' -o "$BINFIX/ours.bin" ./cmd/x ) || exit 1
( cd "$BINFIX/foreign" && GOFLAGS=-mod=mod go build -trimpath -ldflags '-s -w' -o "$BINFIX/foreign.bin" ./cmd/x ) || exit 1

# The fixtures are only evidence if they differ in the one way the sweep reads.
# Asserted rather than assumed: a toolchain change that stopped stamping the
# module path would turn every ownership test below into a test of nothing.
if ! LC_ALL=C grep -qF 'github.com/burrowee-git/' "$BINFIX/ours.bin"; then
    echo "FAIL: the 'ours' fixture carries no burrowee module stamp — every" >&2
    echo "      ownership assertion below would be vacuous." >&2
    exit 1
fi
if LC_ALL=C grep -qF 'github.com/burrowee-git/' "$BINFIX/foreign.bin"; then
    echo "FAIL: the 'foreign' fixture carries a burrowee module stamp — 'ours'" >&2
    echo "      and 'not ours' would produce identical state." >&2
    exit 1
fi

# kit <dir> <comp> <scheme> <version-file> <bins…> — assemble a release kit's
# migrations/ exactly as tools/payload.sh does: the shared files from
# inner/_shared/migrations plus the component's own conf + ledger.
kit() {
    _k_dir="$1"; _k_comp="$2"; _k_scheme="$3"; _k_vf="$4"; shift 4
    mkdir -p "$_k_dir/migrations"
    cp "$SHARED"/run.sh "$SHARED"/upgrade.sh "$SHARED"/lib_paths.sh \
       "$SHARED"/lib_stale_user_bins.sh "$SHARED"/stale_user_bins.sh "$_k_dir/migrations/"
    chmod 0755 "$_k_dir/migrations"/*.sh
    {
        echo "COMP=$_k_comp"
        echo "COMP_HOME_SCHEME=$_k_scheme"
        echo "VERSION_FILE=$_k_vf"
        echo "STALE_USER_BINS=\"$*\""
    } > "$_k_dir/migrations/component.conf"
    printf '# ledger\n0.2.0 stale_user_bins.sh\n' > "$_k_dir/migrations/ledger"
}

EDGE_BINS="burrowee burrowee-edge burrowee-edge-cli burrowee-edge-updater"
CLI_BINS="burrowee burrowee-cli burrowee-cli-updater"

# seed_ours <dir> <name…> — a real stamped burrowee binary under each name.
seed_ours() {
    _so_d="$1"; shift
    mkdir -p "$_so_d"
    for _so_n in "$@"; do cp "$BINFIX/ours.bin" "$_so_d/$_so_n"; chmod 0755 "$_so_d/$_so_n"; done
}
seed_foreign() {
    _sf_d="$1"; shift
    mkdir -p "$_sf_d"
    for _sf_n in "$@"; do cp "$BINFIX/foreign.bin" "$_sf_d/$_sf_n"; chmod 0755 "$_sf_d/$_sf_n"; done
}

# seed_twins <bin-dir> <name…> — the ROOT-INSTALLED copies, in $BIN_DIR.
#
# NOT SCENERY. A per-user binary is stale exactly when $BIN_DIR holds a copy of
# ours under the same name; with no twin it is not a leftover but the only
# install this host has, and the sweep is CORRECT to leave it. So every case
# below that expects a removal has to state the twin, and the cases that expect a
# survival state either the twin (so the survival is about the claim under test)
# or its deliberate absence (so the survival IS the claim).
seed_twins() {
    seed_ours "$@"
}

# run_ladder <kit> <home> <comp-home> <bin-dir> [args…] — run the ladder with
# EVERY system scan redirected into the sandbox. Sets RC and OUT.
#
# LAUNCHD_DIR / SYSTEMD_DIR are not optional here: unit_naming_dir's defaults
# are the REAL /Library/LaunchDaemons and /etc/systemd/system, both of which
# exist on the machines this runs on and neither of which is this suite's to
# read. A test that forgot them would be asserting about the developer's host.
run_ladder() {
    _rl_kit="$1"; _rl_home="$2"; _rl_comp_home="$3"; _rl_bin="$4"; shift 4
    OUT="$(
        HOME="$_rl_home" \
        COMP_HOME="$_rl_comp_home" \
        BIN_DIR="$_rl_bin" \
        LAUNCHD_DIR="$_rl_home/no-launchd" \
        SYSTEMD_DIR="$_rl_home/no-systemd" \
        BURROWEE_LEGACY_HOME_PARENTS="$_rl_home/nowhere" \
        SUDO="/nonexistent-sudo" \
        sh "$_rl_kit/migrations/run.sh" "$@" 2>&1
    )"
    RC=$?
}

echo "== shared migration ladder suite ($(basename "${0}") under ${TEST_SHELL_NAME:-$0}) =="

# ---------------------------------------------------------------------------
# 1. no anchor → the --applies probe selects the rung, it sweeps, exit 2
# ---------------------------------------------------------------------------
t1="$TMP/t1"; kit "$t1" edge root installed-version $EDGE_BINS
h="$t1/home"; ch="$h/root-home/.burrowee/edge"; mkdir -p "$ch"
seed_ours "$h/.local/bin" $EDGE_BINS
seed_twins "$h/usr-local-bin" $EDGE_BINS
run_ladder "$t1" "$h" "$ch" "$h/usr-local-bin"
assert_eq "$RC" 2 "no anchor + a pending sweep must exit 2 (migrations ran)"
assert_contains "$OUT" "no installed version recorded" "the runner must say which input it decided on"
assert_contains "$OUT" "stale_user_bins.sh applies: no recorded version" "the --applies probe must select the rung"
for b in $EDGE_BINS; do
    assert_gone "$h/.local/bin/$b" "the rung must remove the stale per-user copy of $b"
done
assert_present "$ch/migration-receipts/stale_user_bins.sh.done" "the runner must write the receipt"
assert_contains "$(cat "$ch/migration-receipts/stale_user_bins.sh.done")" "comp_home=$ch" "the receipt must record the TREE it was earned for"
# 0700 dir / 0600 file — the receipt names the host's upgrade band and the
# migrated account's home directory.
assert_eq "$(ls -ld "$ch/migration-receipts" | cut -c1-10)" "drwx------" "the receipts directory must be 0700"
assert_eq "$(ls -l "$ch/migration-receipts/stale_user_bins.sh.done" | cut -c1-10)" "-rw-------" "a receipt must be 0600"

# ---------------------------------------------------------------------------
# 2. idempotent: a second run finds the receipt and skips
# ---------------------------------------------------------------------------
run_ladder "$t1" "$h" "$ch" "$h/usr-local-bin"
assert_eq "$RC" 0 "a second run must be a clean no-op"
assert_contains "$OUT" "its receipt records it completed here for $ch" "the skip must name the receipt and the tree"

# ---------------------------------------------------------------------------
# 3. THE NUMERIC GATE: 0.10.0 is NEWER than 0.2.0, not a 0.1.* glob match
# ---------------------------------------------------------------------------
t3="$TMP/t3"; kit "$t3" edge root installed-version $EDGE_BINS
h3="$t3/home"; ch3="$h3/root-home/.burrowee/edge"; mkdir -p "$ch3"
seed_ours "$h3/.local/bin" $EDGE_BINS
seed_twins "$h3/usr-local-bin" $EDGE_BINS
echo "0.10.0" > "$ch3/installed-version"
run_ladder "$t3" "$h3" "$ch3" "$h3/usr-local-bin"
assert_eq "$RC" 0 "installed 0.10.0 is NEWER than target 0.2.0 — nothing may apply"
assert_contains "$OUT" "installed 0.10.0 is not older than 0.2.0" "the skip must name both versions"
assert_present "$h3/.local/bin/burrowee-edge" "a 0.10.0 host must keep its files — the gate is numeric, not a glob"

# ---------------------------------------------------------------------------
# 4. an anchor OLDER than the target fires the gate; the probe is not consulted
# ---------------------------------------------------------------------------
echo "0.1.111" > "$ch3/installed-version"
run_ladder "$t3" "$h3" "$ch3" "$h3/usr-local-bin"
assert_eq "$RC" 2 "installed 0.1.111 is older than 0.2.0 — the rung must run"
assert_contains "$OUT" "installed 0.1.111 is older than 0.2.0" "the gate must say what it compared"
assert_gone "$h3/.local/bin/burrowee-edge" "the gated rung must sweep"

# ---------------------------------------------------------------------------
# 5. THE OPERATOR PATHS, on a host whose anchor already reads 0.2.0 — admin-kr's
#    exact state. This is the case the whole rung exists for.
# ---------------------------------------------------------------------------
t5="$TMP/t5"; kit "$t5" edge root installed-version $EDGE_BINS
h5="$t5/home"; ch5="$h5/root-home/.burrowee/edge"; mkdir -p "$ch5"
seed_ours "$h5/.local/bin" $EDGE_BINS
seed_twins "$h5/usr-local-bin" $EDGE_BINS
echo "0.2.0.2026.08.17.4e43c2ed" > "$ch5/installed-version"

# 5a. the plain ladder does nothing — the gate cannot see a build-only change.
run_ladder "$t5" "$h5" "$ch5" "$h5/usr-local-bin"
assert_eq "$RC" 0 "a 0.2.0 anchor must make the plain ladder a no-op"
assert_present "$h5/.local/bin/burrowee-edge" "the plain ladder must not sweep a 0.2.0 host"

# 5b. --installed-version 0.1.111 reaches the rung.
run_ladder "$t5" "$h5" "$ch5" "$h5/usr-local-bin" --installed-version 0.1.111
assert_eq "$RC" 2 "--installed-version 0.1.111 must reach the rung on a 0.2.0 host"
assert_contains "$OUT" "is NOT read" "the flag must say the anchor was not read"
assert_gone "$h5/.local/bin/burrowee-edge" "--installed-version must let the rung sweep"

# 5c. --rerun-recorded ALONE does not force past the version gate — documented,
#     and asserted so the doc cannot quietly become false.
seed_ours "$h5/.local/bin" $EDGE_BINS
run_ladder "$t5" "$h5" "$ch5" "$h5/usr-local-bin" --rerun-recorded
assert_eq "$RC" 0 "--rerun-recorded alone must not force past the version gate"
assert_present "$h5/.local/bin/burrowee-edge" "--rerun-recorded alone must not sweep a 0.2.0 host"

# 5d. the two together reopen a receipted rung on a 0.2.0 host.
run_ladder "$t5" "$h5" "$ch5" "$h5/usr-local-bin" --installed-version 0.1.111 --rerun-recorded
assert_eq "$RC" 2 "--installed-version + --rerun-recorded must reopen a receipted rung"
assert_contains "$OUT" "re-running it" "reopening a receipted rung must say so out loud"
assert_gone "$h5/.local/bin/burrowee-edge" "the reopened rung must sweep"

# ---------------------------------------------------------------------------
# 6. PROVABLY OURS — a real, compiled, NOT-ours binary under one of our exact
#    names survives, and the run says why.
# ---------------------------------------------------------------------------
t6="$TMP/t6"; kit "$t6" edge root installed-version $EDGE_BINS
h6="$t6/home"; ch6="$h6/root-home/.burrowee/edge"; mkdir -p "$ch6"
seed_ours "$h6/.local/bin" burrowee-edge burrowee-edge-updater
seed_foreign "$h6/.local/bin" burrowee-edge-cli
ln -s /bin/sh "$h6/.local/bin/burrowee"
# A root twin for EVERY name in the fixture, including the ones that must
# survive: without it each survivor would survive for want of a twin and the
# claims under test — no stamp, not a regular file — would assert nothing.
seed_twins "$h6/usr-local-bin" $EDGE_BINS
run_ladder "$t6" "$h6" "$ch6" "$h6/usr-local-bin"
assert_eq "$RC" 2 "a mixed directory still has ours to sweep"
assert_gone "$h6/.local/bin/burrowee-edge" "a stamped copy of ours must go"
assert_present "$h6/.local/bin/burrowee-edge-cli" "a REAL binary that is not ours must be left in place"
assert_contains "$OUT" "carries no burrowee build stamp" "the keep must say why"
assert_present "$h6/.local/bin/burrowee" "a symlink is not a binary this installer placed"
assert_contains "$OUT" "is a symlink" "the symlink keep must say why"

# ---------------------------------------------------------------------------
# 7. GUARD 5 — a unit file protects THE FILE IT NAMES, and only that file
#
#    Observed on a production node 2026-08-18: one
#    /etc/systemd/system/burrowee-edge-updater.service naming the per-user
#    DIRECTORY abandoned the entire sweep, so six gateway names that unit does
#    not mention — and never could — were left shadowing $BIN_DIR on PATH. The
#    guard's direction was never in question; its observed set was.
# ---------------------------------------------------------------------------
t7="$TMP/t7"; kit "$t7" edge root installed-version $EDGE_BINS
h7="$t7/home"; ch7="$h7/root-home/.burrowee/edge"; mkdir -p "$ch7" "$h7/systemd"
seed_ours "$h7/.local/bin" $EDGE_BINS
seed_twins "$h7/usr-local-bin" $EDGE_BINS
printf 'ExecStart=%s/.local/bin/burrowee-edge run\n' "$h7" > "$h7/systemd/burrowee-edge.service"
run_unit_ladder() {
    OUT="$(HOME="$1" COMP_HOME="$2" BIN_DIR="$3" \
        LAUNCHD_DIR="$1/no-launchd" SYSTEMD_DIR="$1/systemd" \
        BURROWEE_LEGACY_HOME_PARENTS="$1/nowhere" SUDO=/nonexistent-sudo \
        sh "$4/migrations/run.sh" 2>&1)"; RC=$?
}
run_unit_ladder "$h7" "$ch7" "$h7/usr-local-bin" "$t7"
assert_eq "$RC" 2 "the rung still applies: only ONE file is protected, not the directory"
assert_present "$h7/.local/bin/burrowee-edge" "a unit names this exact file — removing it can stop a running daemon"
assert_contains "$OUT" "still names $h7/.local/bin/burrowee-edge" "the keep must name both the unit and the file"
for b in burrowee burrowee-edge-cli burrowee-edge-updater; do
    assert_gone "$h7/.local/bin/$b" "no unit names $b; a unit naming a DIFFERENT file must not protect it"
done

# 7b. THE SUBSTRING COLLISION, tested directly. `grep -F "$dir/burrowee-edge"`
#     matches a unit whose ExecStart is "$dir/burrowee-edge-updater", so a match
#     that does not TERMINATE the basename lets the longer name's unit spare the
#     shorter name's file — silently, and in the direction where the shadowing
#     binary survives.
t7b="$TMP/t7b"; kit "$t7b" edge root installed-version $EDGE_BINS
h7b="$t7b/home"; ch7b="$h7b/root-home/.burrowee/edge"; mkdir -p "$ch7b" "$h7b/systemd"
seed_ours "$h7b/.local/bin" $EDGE_BINS
seed_twins "$h7b/usr-local-bin" $EDGE_BINS
printf 'ExecStart=%s/.local/bin/burrowee-edge-updater run\n' "$h7b" > "$h7b/systemd/burrowee-edge-updater.service"
run_unit_ladder "$h7b" "$ch7b" "$h7b/usr-local-bin" "$t7b"
assert_eq "$RC" 2 "the rung must still run"
assert_present "$h7b/.local/bin/burrowee-edge-updater" "the unit names this exact file"
assert_gone "$h7b/.local/bin/burrowee-edge" "burrowee-edge was spared by burrowee-edge-updater's unit — the basename match does not terminate"
assert_gone "$h7b/.local/bin/burrowee" "and the dispatcher was spared by it too"

# 7c. THE TERMINATOR SET, one case per shape a real unit file writes a path in.
#     Each protects burrowee-edge-cli and nothing else, so a terminator the match
#     fails to recognise shows up as a DELETION of a file a unit names.
_t7c=0
for _form in \
    'ExecStart=@P@ --serve' \
    'ExecStart=@P@' \
    'ExecStart=@P@	--serve' \
    '	<string>@P@</string>' \
    'ExecStart="@P@" --serve'; do
    _t7c=$((_t7c + 1))
    d="$TMP/t7c$_t7c"; kit "$d" edge root installed-version $EDGE_BINS
    hd="$d/home"; chd="$hd/root-home/.burrowee/edge"; mkdir -p "$chd" "$hd/systemd"
    seed_ours "$hd/.local/bin" $EDGE_BINS
    seed_twins "$hd/usr-local-bin" $EDGE_BINS
    _p="$hd/.local/bin/burrowee-edge-cli"
    printf '%s\n' "$(printf '%s' "$_form" | sed "s|@P@|$_p|")" > "$hd/systemd/x.service"
    run_unit_ladder "$hd" "$chd" "$hd/usr-local-bin" "$d"
    assert_present "$_p" "a unit names this file as [$_form] and the match did not recognise the terminator"
    assert_gone "$hd/.local/bin/burrowee-edge" "the rest of the sweep must still run"
done

# 7d. A UNIT FILE WITH NO TRAILING NEWLINE — `read` drops a final unterminated
#     line, and a hand-edited unit is exactly where that happens.
t7d="$TMP/t7d"; kit "$t7d" edge root installed-version $EDGE_BINS
h7d="$t7d/home"; ch7d="$h7d/root-home/.burrowee/edge"; mkdir -p "$ch7d" "$h7d/systemd"
seed_ours "$h7d/.local/bin" $EDGE_BINS
seed_twins "$h7d/usr-local-bin" $EDGE_BINS
printf '[Service]\nExecStart=%s/.local/bin/burrowee-edge-cli' "$h7d" > "$h7d/systemd/x.service"
run_unit_ladder "$h7d" "$ch7d" "$h7d/usr-local-bin" "$t7d"
assert_present "$h7d/.local/bin/burrowee-edge-cli" "the last line of a unit file with no trailing newline was not read"

# ---------------------------------------------------------------------------
# 8. PER-USER STATE IS NEVER TOUCHED — only binaries, by exact name
# ---------------------------------------------------------------------------
t8="$TMP/t8"; kit "$t8" edge root installed-version $EDGE_BINS
h8="$t8/home"; ch8="$h8/root-home/.burrowee/edge"; mkdir -p "$ch8" "$h8/.burrowee/edge/identity"
seed_ours "$h8/.local/bin" $EDGE_BINS
seed_ours "$h8/.local/bin" burrowee-edge-notes   # ours by stamp, NOT in $BINS
seed_twins "$h8/usr-local-bin" $EDGE_BINS burrowee-edge-notes
echo "secret" > "$h8/.burrowee/edge/identity/relay_ed.key"
echo '{"paired":true}' > "$h8/.burrowee/edge/console.json"
run_ladder "$t8" "$h8" "$ch8" "$h8/usr-local-bin"
assert_eq "$RC" 2 "the sweep must run"
assert_present "$h8/.burrowee/edge/identity/relay_ed.key" "per-user IDENTITY must never be touched by the binary sweep"
assert_present "$h8/.burrowee/edge/console.json" "per-user pairing state must never be touched"
assert_present "$h8/.local/bin/burrowee-edge-notes" "a name outside \$STALE_USER_BINS must survive — removal is by exact name, never by glob"

# ---------------------------------------------------------------------------
# 9. THE DISPATCHER RULE — removed once a ROOT dispatcher exists, full stop.
#
#    OPERATOR RULING, and it reverses the previous rule. The dispatcher used to
#    be spared whenever any other stamped burrowee-* file was left in the
#    directory. On a host that also carried per-user edge binaries that kept the
#    stale dispatcher alive indefinitely, and because ~/.local/bin precedes
#    /usr/local/bin on a normal PATH it went on answering every `burrowee …`
#    with old code — which is the whole complaint.
#
#    Removing it strands nothing: burrowee's main.go pins only gateway, edge and
#    register to /usr/local/bin and resolves every other component through PATH
#    and then {/usr/local/bin, /opt/homebrew/bin, ~/.local/bin}, so a per-user
#    component it does not pin is still found where it lies. 9a asserts exactly
#    that pairing — the dispatcher goes, the unpinned per-user binary stays.
# ---------------------------------------------------------------------------
t9="$TMP/t9"; kit "$t9" cli user .installed-version $CLI_BINS
h9="$t9/home"; ch9="$h9/.burrowee/cli"; mkdir -p "$ch9"
seed_ours "$h9/.local/bin" $CLI_BINS burrowee-gateway
# Root-installed: the cli's own names and the shared dispatcher. NOT
# burrowee-gateway — a co-installed component that has not been root-collapsed.
seed_twins "$h9/usr-local-bin" $CLI_BINS
run_ladder "$t9" "$h9" "$ch9" "$h9/usr-local-bin"
assert_eq "$RC" 2 "the cli rung must run when its own names are stale"
assert_gone "$h9/.local/bin/burrowee-cli" "the cli's own names go"
assert_gone "$h9/.local/bin/burrowee" "a root dispatcher exists, so the per-user one only shadows it on PATH"
assert_present "$h9/.local/bin/burrowee-gateway" "another component's binary is not the cli's to remove, and it has no root twin"

# 9b. WITH NO ROOT DISPATCHER THE PER-USER ONE STAYS. This is the other half of
#     the same predicate and the reason 9a is safe to state unconditionally: the
#     rule is "a root twin exists", never "delete the dispatcher".
t9b="$TMP/t9b"; kit "$t9b" cli user .installed-version $CLI_BINS
h9b="$t9b/home"; ch9b="$h9b/.burrowee/cli"; mkdir -p "$ch9b"
seed_ours "$h9b/.local/bin" $CLI_BINS
seed_twins "$h9b/usr-local-bin" burrowee-cli burrowee-cli-updater   # no root `burrowee`
run_ladder "$t9b" "$h9b" "$ch9b" "$h9b/usr-local-bin"
assert_eq "$RC" 2 "the cli's own names are still stale"
assert_present "$h9b/.local/bin/burrowee" "with no root dispatcher, the per-user one is the only one there is"
assert_contains "$OUT" "there is no $h9b/usr-local-bin/burrowee to replace it" "the keep must say why"

# 9c. an operator's OWN burrowee-* script is left alone and settles nothing.
t9c="$TMP/t9c"; kit "$t9c" cli user .installed-version $CLI_BINS
h9c="$t9c/home"; ch9c="$h9c/.burrowee/cli"; mkdir -p "$ch9c"
seed_ours "$h9c/.local/bin" $CLI_BINS
seed_foreign "$h9c/.local/bin" burrowee-notes
seed_twins "$h9c/usr-local-bin" $CLI_BINS
run_ladder "$t9c" "$h9c" "$ch9c" "$h9c/usr-local-bin"
assert_eq "$RC" 2 "the rung must run"
assert_gone "$h9c/.local/bin/burrowee" "an operator's own burrowee-* file is not evidence of anything"
assert_present "$h9c/.local/bin/burrowee-notes" "and it must itself be left alone"

# 9d. A FOREIGN /usr/local/bin/burrowee IS NOT A ROOT INSTALL. An operator's own
#     wrapper of that name must not be read as evidence, or the sweep would
#     delete the dispatcher every component still needs.
t9d="$TMP/t9d"; kit "$t9d" cli user .installed-version $CLI_BINS
h9d="$t9d/home"; ch9d="$h9d/.burrowee/cli"; mkdir -p "$ch9d"
seed_ours "$h9d/.local/bin" $CLI_BINS
seed_twins "$h9d/usr-local-bin" burrowee-cli burrowee-cli-updater
seed_foreign "$h9d/usr-local-bin" burrowee
run_ladder "$t9d" "$h9d" "$ch9d" "$h9d/usr-local-bin"
assert_present "$h9d/.local/bin/burrowee" "a foreign file in \$BIN_DIR is not a root install of ours"

# ---------------------------------------------------------------------------
# 10. THE CLI'S ORDINARY HOST — $BIN_DIR IS the per-user dir, so there is
#     nothing stale and the rung must not select itself.
# ---------------------------------------------------------------------------
t10="$TMP/t10"; kit "$t10" cli user .installed-version $CLI_BINS
h10="$t10/home"; ch10="$h10/.burrowee/cli"; mkdir -p "$ch10"
seed_ours "$h10/.local/bin" $CLI_BINS
run_ladder "$t10" "$h10" "$ch10" "$h10/.local/bin"
assert_eq "$RC" 0 "on a default cli host the sweep dir IS \$BIN_DIR — nothing may apply"
for b in $CLI_BINS; do
    assert_present "$h10/.local/bin/$b" "the cli's own live install must never be swept"
done

# ---------------------------------------------------------------------------
# 11. THE OPERATOR'S HOME, NOT $HOME — the sudo trap
#
#     $HOME is root's (as under `curl … | sudo sh`) and $SUDO_USER names the
#     account whose ~/.local/bin actually holds the stale copies. A sweep that
#     read $HOME would find nothing and report success.
# ---------------------------------------------------------------------------
t11="$TMP/t11"; kit "$t11" edge root installed-version $EDGE_BINS
h11="$t11/home"; ch11="$h11/root-home/.burrowee/edge"; mkdir -p "$ch11"
mkdir -p "$h11/parents/alice"
seed_ours "$h11/parents/alice/.local/bin" $EDGE_BINS
seed_ours "$h11/root-home/.local/bin" burrowee-edge-cli   # root's own tree: a decoy
# The twins are shared by both trees, so the decoy is a file the sweep WOULD
# take if it were looking at root's home. Without them it would survive whatever
# home was resolved and the assertion below would pass for the broken version.
seed_twins "$h11/usr-local-bin" $EDGE_BINS
OUT="$(HOME="$h11/root-home" SUDO_USER=alice COMP_HOME="$ch11" BIN_DIR="$h11/usr-local-bin" \
    LAUNCHD_DIR="$h11/no-launchd" SYSTEMD_DIR="$h11/no-systemd" \
    BURROWEE_LEGACY_HOME_PARENTS="$h11/parents" SUDO=/nonexistent-sudo \
    sh "$t11/migrations/run.sh" 2>&1)"; RC=$?
assert_eq "$RC" 2 "the rung must find alice's tree through \$SUDO_USER"
assert_gone "$h11/parents/alice/.local/bin/burrowee-edge" "the sweep must reach \$SUDO_USER's tree"
assert_present "$h11/root-home/.local/bin/burrowee-edge-cli" "a sweep aimed at \$HOME under sudo is aimed at the wrong tree"

# ---------------------------------------------------------------------------
# 12. THE COMMAND LINE — 64, never 2
# ---------------------------------------------------------------------------
t12="$TMP/t12"; kit "$t12" edge root installed-version $EDGE_BINS
h12="$t12/home"; ch12="$h12/root-home/.burrowee/edge"; mkdir -p "$ch12"
run_ladder "$t12" "$h12" "$ch12" "$h12/usr-local-bin" --nope
assert_eq "$RC" 64 "an unknown flag must exit 64 (EX_USAGE), not 2"
run_ladder "$t12" "$h12" "$ch12" "$h12/usr-local-bin" --installed-version 0.1.x
assert_eq "$RC" 64 "an unparseable version must be refused, never rounded to 0.1.0"
assert_contains "$OUT" "nothing has been touched" "a refusal must say nothing was touched"
run_ladder "$t12" "$h12" "$ch12" "$h12/usr-local-bin" --installed-version ""
assert_eq "$RC" 64 "an EMPTY --installed-version must be refused, not read as 'not given'"
run_ladder "$t12" "$h12" "$ch12" "$h12/usr-local-bin" --help
assert_eq "$RC" 0 "--help must exit 0"
assert_contains "$OUT" "usage: sh" "--help must print the usage on stdout"

# ---------------------------------------------------------------------------
# 13. A MISSING TREE: a no-op without the flag, a REFUSAL with it
# ---------------------------------------------------------------------------
t13="$TMP/t13"; kit "$t13" edge root installed-version $EDGE_BINS
h13="$t13/home"; mkdir -p "$h13"
run_ladder "$t13" "$h13" "$h13/absent-tree" "$h13/usr-local-bin"
assert_eq "$RC" 0 "an absent tree with no flag is a warned no-op"
assert_contains "$OUT" "WITHOUT EVALUATING IT" "the no-op must say it evaluated nothing"
run_ladder "$t13" "$h13" "$h13/absent-tree" "$h13/usr-local-bin" --installed-version 0.1.111
assert_eq "$RC" 1 "an absent tree the operator asserted a version FOR is a refusal"

# ---------------------------------------------------------------------------
# 14. AN INCOMPLETE RELEASE IS FATAL, never a quiet skip
# ---------------------------------------------------------------------------
t14="$TMP/t14"; kit "$t14" edge root installed-version $EDGE_BINS
h14="$t14/home"; ch14="$h14/root-home/.burrowee/edge"; mkdir -p "$ch14"
rm -f "$t14/migrations/stale_user_bins.sh"
run_ladder "$t14" "$h14" "$ch14" "$h14/usr-local-bin"
assert_eq "$RC" 1 "a ledger row whose script is missing must fail the run"
assert_contains "$OUT" "THIS RELEASE IS INCOMPLETE" "it must say the release is incomplete"

t14b="$TMP/t14b"; kit "$t14b" edge root installed-version $EDGE_BINS
h14b="$t14b/home"; ch14b="$h14b/root-home/.burrowee/edge"; mkdir -p "$ch14b"
rm -f "$t14b/migrations/ledger"
run_ladder "$t14b" "$h14b" "$ch14b" "$h14b/usr-local-bin"
assert_eq "$RC" 1 "a missing ledger must fail, not read as an empty ladder"

t14c="$TMP/t14c"; kit "$t14c" edge root installed-version $EDGE_BINS
h14c="$t14c/home"; ch14c="$h14c/root-home/.burrowee/edge"; mkdir -p "$ch14c"
printf '# nothing here\n' > "$t14c/migrations/ledger"
run_ladder "$t14c" "$h14c" "$ch14c" "$h14c/usr-local-bin"
assert_eq "$RC" 1 "a ledger with no rows must fail — 'no rungs' and 'rungs lost' are the same exit 0"

t14d="$TMP/t14d"; kit "$t14d" edge root installed-version $EDGE_BINS
h14d="$t14d/home"; ch14d="$h14d/root-home/.burrowee/edge"; mkdir -p "$ch14d"
printf 'latest stale_user_bins.sh\n' > "$t14d/migrations/ledger"
run_ladder "$t14d" "$h14d" "$ch14d" "$h14d/usr-local-bin"
assert_eq "$RC" 1 "a ledger row with a non-numeric target must fail, not silently become 0.0.0"

t14e="$TMP/t14e"; kit "$t14e" edge root installed-version $EDGE_BINS
h14e="$t14e/home"; ch14e="$h14e/root-home/.burrowee/edge"; mkdir -p "$ch14e"
rm -f "$t14e/migrations/component.conf"
run_ladder "$t14e" "$h14e" "$ch14e" "$h14e/usr-local-bin"
assert_eq "$RC" 1 "a missing component.conf must fail — the runner has no component defaults"

# ---------------------------------------------------------------------------
# 15. A LOST RECEIPT IS EXIT 3 — ran, but do not record the version
# ---------------------------------------------------------------------------
t15="$TMP/t15"; kit "$t15" edge root installed-version $EDGE_BINS
h15="$t15/home"; ch15="$h15/root-home/.burrowee/edge"; mkdir -p "$ch15"
seed_ours "$h15/.local/bin" $EDGE_BINS
seed_twins "$h15/usr-local-bin" $EDGE_BINS
# The receipts path is blocked by a FILE where the directory has to go, so
# mkdir -p fails while $COMP_HOME itself stays writable — the receipt is lost
# and nothing else is.
: > "$ch15/migration-receipts"
run_ladder "$t15" "$h15" "$ch15" "$h15/usr-local-bin"
assert_eq "$RC" 3 "a rung that ran but could not be recorded must exit 3, not 2"
assert_contains "$OUT" "NOT recorded" "exit 3 must name the unrecorded rung"
assert_gone "$h15/.local/bin/burrowee-edge" "exit 3 still means the rung RAN"

# ---------------------------------------------------------------------------
# 16. A RECEIPT FOR ANOTHER TREE SETTLES NOTHING HERE
# ---------------------------------------------------------------------------
t16="$TMP/t16"; kit "$t16" edge root installed-version $EDGE_BINS
h16="$t16/home"; ch16="$h16/root-home/.burrowee/edge"; mkdir -p "$ch16/migration-receipts"
seed_ours "$h16/.local/bin" $EDGE_BINS
seed_twins "$h16/usr-local-bin" $EDGE_BINS
printf 'stale_user_bins.sh\ncomp_home=/some/other/tree\n' > "$ch16/migration-receipts/stale_user_bins.sh.done"
run_ladder "$t16" "$h16" "$ch16" "$h16/usr-local-bin"
assert_eq "$RC" 2 "a receipt earned for another tree must not skip this one"
assert_contains "$OUT" "was earned for /some/other/tree" "the re-evaluation must name the foreign tree"

# 16b. and a receipt that records no tree at all falls through the same way.
t16b="$TMP/t16b"; kit "$t16b" edge root installed-version $EDGE_BINS
h16b="$t16b/home"; ch16b="$h16b/root-home/.burrowee/edge"; mkdir -p "$ch16b/migration-receipts"
seed_ours "$h16b/.local/bin" $EDGE_BINS
seed_twins "$h16b/usr-local-bin" $EDGE_BINS
printf 'stale_user_bins.sh\n' > "$ch16b/migration-receipts/stale_user_bins.sh.done"
run_ladder "$t16b" "$h16b" "$ch16b" "$h16b/usr-local-bin"
assert_eq "$RC" 2 "an unprovenanced receipt must not skip a tree it cannot speak for"
assert_contains "$OUT" "records no tree" "the re-evaluation must say the receipt cannot answer"

# ---------------------------------------------------------------------------
# 17. upgrade.sh — THE OVERRIDE, on admin-kr's exact state.
#
# The anchor reads a 0.2.0 RELEASE STAMP and the host has stale copies. The gate
# compares only MAJOR.MINOR.PATCH and deliberately ignores the .date.sha tail,
# so a host that changed BUILD without changing SEMVER is invisible to it and
# looks already migrated. That is precisely the host the sweep exists for, and
# the plain ladder can do nothing about it.
# ---------------------------------------------------------------------------
run_upgrade() {
    _ru_kit="$1"; _ru_home="$2"; _ru_comp_home="$3"; _ru_bin="$4"; shift 4
    OUT="$(
        HOME="$_ru_home" \
        COMP_HOME="$_ru_comp_home" \
        BIN_DIR="$_ru_bin" \
        LAUNCHD_DIR="$_ru_home/no-launchd" \
        SYSTEMD_DIR="$_ru_home/no-systemd" \
        BURROWEE_LEGACY_HOME_PARENTS="$_ru_home/nowhere" \
        SUDO="/nonexistent-sudo" \
        sh "$_ru_kit/migrations/upgrade.sh" "$@" 2>&1
    )"
    RC=$?
}

t17="$TMP/t17"; kit "$t17" edge root installed-version $EDGE_BINS
h17="$t17/home"; ch17="$h17/root-home/.burrowee/edge"; mkdir -p "$ch17"
seed_ours "$h17/.local/bin" $EDGE_BINS
seed_twins "$h17/usr-local-bin" $EDGE_BINS
echo "0.2.0.2026.08.17.4e43c2ed" > "$ch17/installed-version"

# 17a. the plain ladder does nothing — the state the operator is stuck in.
run_ladder "$t17" "$h17" "$ch17" "$h17/usr-local-bin"
assert_eq "$RC" 0 "precondition: the plain ladder must be a no-op on a 0.2.0 anchor"
assert_present "$h17/.local/bin/burrowee-edge" "precondition: the stale copy must survive the plain ladder"

# 17b. upgrade.sh forces it, and SAYS WHAT IT WILL RE-RUN before running it.
run_upgrade "$t17" "$h17" "$ch17" "$h17/usr-local-bin" 0.2.0
assert_eq "$RC" 2 "upgrade.sh must force the rung on a same-semver host"
assert_contains "$OUT" "every rung in this kit will be re-run" "it must list the rungs BEFORE running them"
assert_contains "$OUT" "stale_user_bins.sh (target 0.2.0)" "the list must name the rung and its target"
assert_gone "$h17/.local/bin/burrowee-edge" "the forced rung must sweep"

# 17c. idempotent — an operator will run it twice.
run_upgrade "$t17" "$h17" "$ch17" "$h17/usr-local-bin" 0.2.0
assert_eq "$RC" 2 "a second forced run must still report that the rung ran"

# 17d. THE CROSS-CHECK IS ENFORCED, not decorative. An operator standing in a
# 0.2.0 kit who types 0.3.0 has a wrong belief about their host.
run_upgrade "$t17" "$h17" "$ch17" "$h17/usr-local-bin" 0.3.0
assert_eq "$RC" 64 "a version that does not match the kit's ladder must be refused"
assert_contains "$OUT" "tops out at 0.2.0" "the refusal must name BOTH values"
assert_contains "$OUT" "nothing has been touched" "a refusal must say nothing was touched"

# 17e. it INSTALLS NOTHING — asserted so a future edit cannot quietly fold the
# installer back in.
mkdir -p "$h17/usr-local-bin"
seed_ours "$h17/usr-local-bin" burrowee-edge
_before="$(ls -l "$h17/usr-local-bin")"
run_upgrade "$t17" "$h17" "$ch17" "$h17/usr-local-bin" 0.2.0
assert_eq "$(ls -l "$h17/usr-local-bin")" "$_before" "upgrade.sh must not place, replace or remove anything in \$BIN_DIR"

# 17f. it propagates the ladder's code rather than its own feeling about it.
t17g="$TMP/t17g"; kit "$t17g" edge root installed-version $EDGE_BINS
h17g="$t17g/home"; mkdir -p "$h17g"
rm -f "$t17g/migrations/stale_user_bins.sh"
run_upgrade "$t17g" "$h17g" "$h17g/absent" "$h17g/bin" 0.2.0
assert_eq "$RC" 1 "a ladder that refuses must propagate exit 1, not be swallowed"

# 17g. the command line: one version, and it must parse.
run_upgrade "$t17" "$h17" "$ch17" "$h17/usr-local-bin"
assert_eq "$RC" 64 "no version is a usage error"
run_upgrade "$t17" "$h17" "$ch17" "$h17/usr-local-bin" 0.2.0 extra
assert_eq "$RC" 64 "a second argument must be rejected, never silently discarded"
run_upgrade "$t17" "$h17" "$ch17" "$h17/usr-local-bin" 0.2.x
assert_eq "$RC" 64 "an unparseable version must be refused, never rounded to 0.2.0"

# ---------------------------------------------------------------------------
# 18. THE ROOT-TWIN PREDICATE — what makes a per-user copy "stale" rather than
#     "the install", and the operator's ruling about the cli.
#
#     "for burrowee-cli, once root installed, all user's user home burrowee-cli
#     get obsolete, and require to use root cli." The rule needs no version
#     policy and no cross-component coupling: today there is no
#     /usr/local/bin/burrowee-cli anywhere in the field, so a per-user cli is a
#     LIVE install and survives; the day the cli's root collapse lands and a
#     twin appears, the same predicate sweeps it with no rule change at all.
#
#     The kit here is the cli's, with $BIN_DIR pointed somewhere else (an
#     explicit PREFIX), because on a DEFAULT cli host the sweep dir IS $BIN_DIR
#     and the rung is a no-op — case 10.
# ---------------------------------------------------------------------------
t18="$TMP/t18"; kit "$t18" cli user .installed-version $CLI_BINS
h18="$t18/home"; ch18="$h18/.burrowee/cli"; mkdir -p "$ch18"
seed_ours "$h18/.local/bin" $CLI_BINS
seed_twins "$h18/usr-local-bin" burrowee            # a root dispatcher only
run_ladder "$t18" "$h18" "$ch18" "$h18/usr-local-bin"
assert_eq "$RC" 2 "the dispatcher has a root twin, so the rung has something to do"
assert_present "$h18/.local/bin/burrowee-cli" "no root burrowee-cli exists — this is a LIVE cli install, not a stale copy"
assert_present "$h18/.local/bin/burrowee-cli-updater" "same for the updater it ships with"
assert_gone "$h18/.local/bin/burrowee" "the dispatcher has a root twin and must go"

# 18b. the day the root cli lands, the per-user copies are obsolete.
t18b="$TMP/t18b"; kit "$t18b" cli user .installed-version $CLI_BINS
h18b="$t18b/home"; ch18b="$h18b/.burrowee/cli"; mkdir -p "$ch18b"
seed_ours "$h18b/.local/bin" $CLI_BINS
seed_twins "$h18b/usr-local-bin" $CLI_BINS
run_ladder "$t18b" "$h18b" "$ch18b" "$h18b/usr-local-bin"
assert_eq "$RC" 2 "the rung must run"
for b in $CLI_BINS; do
    assert_gone "$h18b/.local/bin/$b" "$b is root-installed now, so the per-user copy only shadows it on PATH"
done

# 18c. NOTHING root-installed at all: the rung must not even select itself, or
#      the runner buys a daemon stop for a sweep that will decline everything.
t18c="$TMP/t18c"; kit "$t18c" edge root installed-version $EDGE_BINS
h18c="$t18c/home"; ch18c="$h18c/root-home/.burrowee/edge"; mkdir -p "$ch18c"
seed_ours "$h18c/.local/bin" $EDGE_BINS
run_ladder "$t18c" "$h18c" "$ch18c" "$h18c/usr-local-bin"
assert_eq "$RC" 0 "with no root-installed twin anywhere there is nothing stale — the rung must not apply"
for b in $EDGE_BINS; do
    assert_present "$h18c/.local/bin/$b" "$b is the only copy on this host; removing it is an uninstall"
done

# ---------------------------------------------------------------------------
# 19. admin-kr's TREE, for the shared ladder: a cross-component per-user
#     directory, a partial root install, and one unit still pointing into it.
#
#     The unit names burrowee-edge-updater. Under the directory-scoped guard it
#     abandoned the whole sweep. It must now protect that one file and nothing
#     else — and the names with no root twin must survive on their own merits,
#     not because a blocker stopped the run.
# ---------------------------------------------------------------------------
t19="$TMP/t19"; kit "$t19" edge root installed-version $EDGE_BINS
h19="$t19/home"; ch19="$h19/root-home/.burrowee/edge"; mkdir -p "$ch19" "$h19/systemd"
seed_ours "$h19/.local/bin" $EDGE_BINS burrowee-gateway burrowee-gateway-cli burrowee-cli
# Root-installed: the dispatcher, edge's daemon and cli, and the gateway's pair.
# NOT burrowee-edge-updater and NOT burrowee-cli.
seed_twins "$h19/usr-local-bin" burrowee burrowee-edge burrowee-edge-cli burrowee-gateway burrowee-gateway-cli
printf 'ExecStart=%s/.local/bin/burrowee-edge-updater run\n' "$h19" > "$h19/systemd/burrowee-edge-updater.service"
run_unit_ladder "$h19" "$ch19" "$h19/usr-local-bin" "$t19"
assert_eq "$RC" 2 "one unit naming one file must not abandon the sweep"
assert_gone "$h19/.local/bin/burrowee" "the shadowing dispatcher is the whole complaint and must go"
assert_gone "$h19/.local/bin/burrowee-edge" "root-installed and named by no unit"
assert_gone "$h19/.local/bin/burrowee-edge-cli" "root-installed and named by no unit"
assert_present "$h19/.local/bin/burrowee-edge-updater" "a unit names this exact file"
assert_present "$h19/.local/bin/burrowee-cli" "no root twin: a LIVE cli install"
assert_present "$h19/.local/bin/burrowee-gateway" "not one of edge's names — removal is by exact name, never across components"
assert_present "$h19/.local/bin/burrowee-gateway-cli" "same"

# ---------------------------------------------------------------------------
# 20. AFTER A REMOVAL, THE RUN SAYS HOW TO CLEAR THE OPERATOR'S SHELL CACHE
#
#     Observed on a production node 2026-08-18, immediately after the sweep did
#     exactly the right thing:
#
#       ✓ gateway … installed and its 0.2.0 migrations forced
#       $ burrowee gateway doctor
#       -bash: /home/ubuntu/.local/bin/burrowee: No such file or directory
#
#     bash re-execs the absolute path it cached; the operator's shell predated
#     the sweep, so it still held a path that had just been removed. A
#     successful cleanup whose next command fails reads as a broken install.
#     The installer cannot reload the caller's shell — it is a child of
#     `sudo sh` — so the deliverable is a precise sentence, printed only when a
#     removal actually happened.
# ---------------------------------------------------------------------------

# passwd_stub <dir> <user> <home> <shell> — a `getent` that answers for exactly
# ONE account, with the home and LOGIN SHELL this fixture chose.
#
# A STUB RATHER THAN THE HOST'S OWN passwd, because the claim under test is
# WHICH field of WHICH account's entry is read. Answering from the machine's
# real passwd file makes the fixture's shell whatever the CI image gives its
# build account — the same shell for the right answer and the wrong one, which
# is an assertion that cannot fail. Every other name is delegated to the real
# getent: run.sh resolves `root` through it too, and a stub that refused
# everything would change behaviour this section is not about.
passwd_stub() {
    mkdir -p "$1"
    {
        echo '#!/bin/sh'
        echo "if [ \"\$1\" = passwd ] && [ \"\$2\" = '$2' ]; then"
        echo "    echo '$2:x:1000:1000:fixture:$3:$4'"
        echo '    exit 0'
        echo 'fi'
        echo '[ -x /usr/bin/getent ] || exit 2'
        echo 'exec /usr/bin/getent "$@"'
    } > "$1/getent"
    chmod 0755 "$1/getent"
}

# run_hint_ladder <home> <comp-home> <bin-dir> <kit> <stub-dir> <sudo-user>
#                 <SHELL-value> [args…]
#
# $SUDO_USER AND $SHELL ARE ALWAYS SET TO DIFFERENT SHELLS BY EVERY CALLER
# BELOW. That is the whole discipline of this section: with both naming the
# same shell the assertion passes whichever variable the code reads.
run_hint_ladder() {
    _rh_home="$1"; _rh_ch="$2"; _rh_bin="$3"; _rh_kit="$4"
    _rh_stub="$5"; _rh_user="$6"; _rh_shell="$7"; shift 7
    OUT="$(
        HOME="$_rh_home" COMP_HOME="$_rh_ch" BIN_DIR="$_rh_bin" \
        LAUNCHD_DIR="$_rh_home/no-launchd" SYSTEMD_DIR="$_rh_home/no-systemd" \
        BURROWEE_LEGACY_HOME_PARENTS="$_rh_home/nowhere" SUDO=/nonexistent-sudo \
        PATH="$_rh_stub:$PATH" SUDO_USER="$_rh_user" SHELL="$_rh_shell" \
        sh "$_rh_kit/migrations/run.sh" "$@" 2>&1
    )"
    RC=$?
}

# 20a. the operator's login shell is bash and $SHELL says fish. bash is the one
#      that actually strands — it re-execs the cached path and does not
#      re-search — so this is the reported case, named by name.
t20="$TMP/t20"; kit "$t20" edge root installed-version $EDGE_BINS
h20="$t20/home"; ch20="$h20/root-home/.burrowee/edge"; mkdir -p "$ch20"
seed_ours "$h20/.local/bin" $EDGE_BINS
seed_twins "$h20/usr-local-bin" $EDGE_BINS
passwd_stub "$TMP/stub-bash" fixtureop "$h20" /bin/bash
run_hint_ladder "$h20" "$ch20" "$h20/usr-local-bin" "$t20" "$TMP/stub-bash" fixtureop /usr/bin/fish
assert_eq "$RC" 2 "the rung must run and sweep"
assert_gone "$h20/.local/bin/burrowee" "precondition: something must have been removed for a hint to be due"
assert_contains "$OUT" "command-hash table" "a run that removed a shadowing binary must say why the next command can fail"
assert_contains "$OUT" "clear it in bash: hash -r" "the hint must name \$SUDO_USER's shell and its command"
assert_lacks "$OUT" "fish has no" "the hint followed \$SHELL instead of \$SUDO_USER's passwd entry"

# 20b. the mirror, and the reason $SHELL cannot be the source: same host, the
#      two variables swapped. fish 4.0.6 has NO `hash` builtin (`hash -r` is
#      "Unknown command: hash", exit 127) and re-resolves a removed command by
#      itself, so it must be told what happened and given no command at all.
t20b="$TMP/t20b"; kit "$t20b" edge root installed-version $EDGE_BINS
h20b="$t20b/home"; ch20b="$h20b/root-home/.burrowee/edge"; mkdir -p "$ch20b"
seed_ours "$h20b/.local/bin" $EDGE_BINS
seed_twins "$h20b/usr-local-bin" $EDGE_BINS
passwd_stub "$TMP/stub-fish" fixtureop "$h20b" /usr/bin/fish
run_hint_ladder "$h20b" "$ch20b" "$h20b/usr-local-bin" "$t20b" "$TMP/stub-fish" fixtureop /bin/bash
assert_eq "$RC" 2 "the rung must run and sweep"
assert_contains "$OUT" "command-hash table" "the hint is still due — a removal happened"
assert_contains "$OUT" "fish has no \`hash\` builtin" "fish must be told why there is nothing to run"
assert_lacks "$OUT" "hash -r" "fish was handed a command that is not a fish command"

# 20c. A SWEEP THAT REMOVED NOTHING SAYS NOTHING ABOUT SHELLS. No root twins, so
#      every candidate is decided no-twin: the sweep runs in full, names what it
#      kept, and removes nothing. A hint here would be false — no path went away
#      — and an operator who sees it on every converged run stops reading it on
#      the run where it is true. The gate is forced with --installed-version
#      because with nothing to remove the --applies probe would not select the
#      rung at all, and a rung that never ran proves nothing about its output.
t20c="$TMP/t20c"; kit "$t20c" edge root installed-version $EDGE_BINS
h20c="$t20c/home"; ch20c="$h20c/root-home/.burrowee/edge"; mkdir -p "$ch20c"
seed_ours "$h20c/.local/bin" $EDGE_BINS
# ITS OWN STUB, because the stub carries the HOME as well as the shell. Reusing
# 20a's pointed the sweep at 20a's already-emptied tree, where "no hint" was true
# for the wrong reason — a fixture in which the right and the wrong behaviour
# produce identical output is not evidence about either.
passwd_stub "$TMP/stub-bash-c" fixtureop "$h20c" /bin/bash
run_hint_ladder "$h20c" "$ch20c" "$h20c/usr-local-bin" "$t20c" "$TMP/stub-bash-c" fixtureop /usr/bin/fish \
    --installed-version 0.1.111
assert_eq "$RC" 2 "the forced gate must run the rung"
assert_contains "$OUT" "kept $h20c/.local/bin/burrowee-edge" "precondition: the sweep must have reached every candidate"
assert_lacks "$OUT" "command-hash table" "a sweep that removed nothing printed the shell hint"
assert_lacks "$OUT" "hash -r" "a sweep that removed nothing named a rehash command"

# 20d. A $SUDO_USER WITH NO PASSWD ENTRY still gets usable output, and does not
#      cost the migration its exit code: by the time the hint prints, the
#      binaries are placed and the state is migrated, and a message is not worth
#      an exit code. The generic form is the POSIX command plus the escape hatch
#      that is true of every shell there is — never a guess at which one.
t20d="$TMP/t20d"; kit "$t20d" edge root installed-version $EDGE_BINS
h20d="$t20d/home"; ch20d="$h20d/root-home/.burrowee/edge"; mkdir -p "$ch20d"
seed_ours "$h20d/.local/bin" $EDGE_BINS
seed_twins "$h20d/usr-local-bin" $EDGE_BINS
mkdir -p "$TMP/stub-none"
run_hint_ladder "$h20d" "$ch20d" "$h20d/usr-local-bin" "$t20d" "$TMP/stub-none" no-such-burrowee-op-9x /bin/bash
assert_eq "$RC" 2 "an unresolvable login shell must not fail the migration"
assert_gone "$h20d/.local/bin/burrowee" "the sweep itself must still have run"
assert_contains "$OUT" "command-hash table" "the hint is due whether or not the shell could be named"
assert_contains "$OUT" "or just open a new shell" "an unnameable shell gets the escape hatch"
assert_contains "$OUT" "hash -r" "and the POSIX form"

# ---------------------------------------------------------------------------
# 21. THE TWO-COPY GUARD.
#
#     lib_stale_user_bins.sh exists TWICE: here, staged into the edge and cli
#     kits, and in the gateway repo, whose ladder tools/payload.sh assembles
#     wholly from that worktree (takes_shared_ladder deliberately excludes the
#     gateway). They cannot be one file — two repos, and the gateway's own suite
#     runs the rung out of its own migrations/ directory — so the drift is
#     guarded instead of prevented.
#
#     Everything between the SHARED SWEEP CONTRACT sentinels is byte-identical in
#     both copies, and both repos pin the SAME sha256 of it. Editing either copy
#     reddens that repo's test, and the only digest that makes both green again
#     is one both copies produce. Nothing outside the sentinels is compared,
#     which is what lets the two preambles differ.
#
#     If this fails and the edit was intended: apply the same edit to
#     burrowee-git/gateway migrations/lib_stale_user_bins.sh, then update the
#     digest in BOTH repos (here, and sweepContractDigest in the gateway's
#     internal/updatescript/migration_stale_user_bins_adminkr_test.go).
# ---------------------------------------------------------------------------
#     SKIPPED UNDER THE MUTATION HARNESS. tools/test-shared-migrations-mutants.sh
#     points $SHARED_MIGRATIONS_DIR at a deliberately broken COPY, and every one
#     of its mutants changes the region — so this check would redden for all of
#     them and score each as "killed" whether or not any behavioural assertion
#     noticed. A guard that answers for claims it never made is exactly the
#     defect this suite exists to catch, so it only speaks for the checked-in
#     file.
SWEEP_CONTRACT_DIGEST="089d7aaf663ca78e9d945b0d9d5d6b0bbc54d2787752a478e026e45b7fbf1ce0"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum < "$1" | cut -d' ' -f1
    else
        shasum -a 256 < "$1" | cut -d' ' -f1
    fi
}

if [ -n "${SHARED_MIGRATIONS_DIR:-}" ]; then
    echo "-- contract digest skipped: running against an injected \$SHARED_MIGRATIONS_DIR"
else
_lib="$SHARED/lib_stale_user_bins.sh"
_region="$TMP/contract-region"
awk '/^# === SHARED SWEEP CONTRACT BEGIN ===$/{p=1} p{print} /^# === SHARED SWEEP CONTRACT END ===$/{if(p)exit}' \
    "$_lib" > "$_region"
# A region that came out EMPTY would hash to a constant and could be pinned, so
# the sentinels are asserted before the digest is compared.
assert_contains "$(head -1 "$_region")" "SHARED SWEEP CONTRACT BEGIN" "the contract's opening sentinel is missing from $_lib"
assert_contains "$(tail -1 "$_region")" "SHARED SWEEP CONTRACT END" "the contract's closing sentinel is missing from $_lib"
assert_eq "$(sha256_of "$_region")" "$SWEEP_CONTRACT_DIGEST" \
    "the shared sweep contract region changed — apply the same edit to the gateway repo's copy and update the digest in BOTH"
fi

# ---------------------------------------------------------------------------
echo "== $CASES checks, $FAILED failed =="
[ "$FAILED" = 0 ] || exit 1
