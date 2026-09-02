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

# THE AMBIENT $SUDO_USER IS CLEARED ONCE, HERE. It is the single variable that
# decides which tree the adoption rung takes, so a suite that let it through
# would resolve fixture sources out of the real home directory of whoever
# happened to run it from a `sudo -s`. Cases that need one set it themselves, as
# a prefix on the invocation under test (case 11, case 28h).
SUDO_USER=""
export SUDO_USER

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
# A binary that STAYS UP, for the adoption rung's liveness probe (cases 24+).
# It has to be a real executable rather than a shell script: the probe reads
# `ps -o args=`, and a script launched by its shebang appears as
# "/bin/sh /path/burrowee-edge", so a shell stub would be testing whether the
# pattern happens to match an interpreter's command line rather than whether it
# recognises the daemon.
mkdir -p "$BINFIX/ours/cmd/sleeper"
printf 'package main\n\nimport "time"\n\nfunc main() { time.Sleep(300 * time.Second) }\n' > "$BINFIX/ours/cmd/sleeper/main.go"

if ! command -v go >/dev/null 2>&1; then
    echo "FAIL: go is not on PATH — this suite's whole ownership claim rests on" >&2
    echo "      real stamped binaries and it must not degrade to shell stubs." >&2
    exit 1
fi
( cd "$BINFIX/ours" && GOFLAGS=-mod=mod go build -trimpath -ldflags '-s -w' -o "$BINFIX/ours.bin" ./cmd/x ) || exit 1
( cd "$BINFIX/foreign" && GOFLAGS=-mod=mod go build -trimpath -ldflags '-s -w' -o "$BINFIX/foreign.bin" ./cmd/x ) || exit 1
( cd "$BINFIX/ours" && GOFLAGS=-mod=mod go build -trimpath -ldflags '-s -w' -o "$BINFIX/sleeper.bin" ./cmd/sleeper ) || exit 1

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
    # BY GLOB, exactly as tools/payload.sh's shared_migration_scripts stages
    # them. The list used to be spelled out here, and a hand-written list is a
    # list that stops matching: the first shared rung added after it was written
    # would be absent from every kit this suite builds while being present in
    # every kit that ships, so the suite would be testing a ladder nobody runs.
    cp "$SHARED"/*.sh "$_k_dir/migrations/"
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
assert_present "$ch/migration-receipts/stale_user_bins.sh@0.2.0.done" "the runner must write the ITEM's receipt, keyed by script AND target"
assert_contains "$(cat "$ch/migration-receipts/stale_user_bins.sh@0.2.0.done")" "comp_home=$ch" "the receipt must record the TREE it was earned for"
assert_contains "$(cat "$ch/migration-receipts/stale_user_bins.sh@0.2.0.done")" "target=0.2.0" "the receipt must record the ledger TARGET it was earned for"
# 0700 dir / 0600 file — the receipt names the host's upgrade band and the
# migrated account's home directory.
assert_eq "$(ls -ld "$ch/migration-receipts" | cut -c1-10)" "drwx------" "the receipts directory must be 0700"
assert_eq "$(ls -l "$ch/migration-receipts/stale_user_bins.sh@0.2.0.done" | cut -c1-10)" "-rw-------" "a receipt must be 0600"

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
# 15b. A DEFERRED RUNG IS ALSO EXIT 3 — it did not run, and nothing above it may
#
# A rung that exits 3 is saying "this host needs me, I could not run, and I
# changed nothing" — the shape adopt_updater_unit.sh uses when it cannot reach
# root on a host with no tty. Every non-zero rung exit used to become the
# runner's exit 1, which callers treat as fatal: updater.update.sh stops there,
# BEFORE it restarts the updater, and the updater is the only automatic delivery
# channel a host has. So the two have to be told apart here.
# ---------------------------------------------------------------------------
t15b="$TMP/t15b"; kit "$t15b" edge root installed-version $EDGE_BINS
h15b="$t15b/home"; ch15b="$h15b/root-home/.burrowee/edge"; mkdir -p "$ch15b"
seed_ours "$h15b/.local/bin" $EDGE_BINS
seed_twins "$h15b/usr-local-bin" $EDGE_BINS
# A rung that defers, ordered BELOW the sweep, so the sweep is the evidence that
# the walk stopped: its stale per-user binaries must still be there afterwards.
{
    echo '#!/bin/sh'
    echo '[ "${1:-}" = --applies ] && exit 0'
    echo 'echo "defer_me: an operator has to do something first" >&2'
    echo 'exit 3'
} > "$t15b/migrations/defer_me.sh"
chmod 0755 "$t15b/migrations/defer_me.sh"
printf '0.2.0 defer_me.sh\n0.2.0 stale_user_bins.sh\n' > "$t15b/migrations/ledger"
run_ladder "$t15b" "$h15b" "$ch15b" "$h15b/usr-local-bin"
assert_eq "$RC" 3 "a rung that DEFERRED must exit 3 (still pending), not 1 (failed)"
assert_contains "$OUT" "defer_me.sh DEFERRED" "exit 3 must name the deferred rung"
assert_contains "$OUT" "nothing above it ran" "the runner must say the walk stopped"
assert_gone "$ch15b/migration-receipts/defer_me.sh@0.2.0.done" "a deferred rung must earn no receipt"
assert_present "$h15b/.local/bin/burrowee-edge" "the rung ABOVE a deferred one must not have run"

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

# run_upgrade_with_prefix <kit> <home> <comp_home> <prefix> <floor…> — the same
# call with NO BIN_DIR and a PREFIX instead, which is the shape the public
# upgrade bootstrap and a hand-run `PREFIX=… sh migrations/upgrade.sh` both
# produce. Nothing in this suite exports BIN_DIR globally, so its absence here
# is real: the destination is whatever upgrade.sh derives from $PREFIX.
run_upgrade_with_prefix() {
    _rup_kit="$1"; _rup_home="$2"; _rup_comp_home="$3"; _rup_prefix="$4"; shift 4
    OUT="$(
        HOME="$_rup_home" \
        COMP_HOME="$_rup_comp_home" \
        PREFIX="$_rup_prefix" \
        LAUNCHD_DIR="$_rup_home/no-launchd" \
        SYSTEMD_DIR="$_rup_home/no-systemd" \
        BURROWEE_LEGACY_HOME_PARENTS="$_rup_home/nowhere" \
        SUDO="/nonexistent-sudo" \
        sh "$_rup_kit/migrations/upgrade.sh" "$@" 2>&1
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
assert_contains "$OUT" "every rung targeting 0.2.0 or newer will be re-run" "it must list the rungs BEFORE running them"
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

# ---------------------------------------------------------------------------
# 17h. THE SPELLING OF THE DESTINATION — the path with no BIN_DIR to pass.
#
# Every scenario above hands the ladder an explicit BIN_DIR. The bootstrap's
# upgrade mode does not: it runs `sh ./migrations/upgrade.sh <floor>` with
# nothing but the environment, so the destination is derived from $PREFIX — and
# $PREFIX is whatever the operator typed. `PREFIX=$HOME/.local/` is not exotic,
# and since the root-only installers' gate started ACCEPTING any spelling that
# resolves to their destination, a loose one now survives the install step
# instead of aborting it.
#
# Derived naively that becomes BIN_DIR=<prefix>//bin. Every filesystem call
# tolerates the doubled slash — which is exactly why this is dangerous. The
# stale-bin sweep's "never sweep the install destination" guard compares
# directory NAMES: `<home>/.local/bin` != `<home>/.local//bin`, so on the CLI's
# ORDINARY host — where the sweep dir and the install destination are one
# directory — the guard stops recognising itself, `system_twin_exists` finds the
# twin through the same doubled slash, and the rung deletes the live install it
# was protecting. Exit 2, "swept", success.
#
# So both spellings must reach the SAME verdict, and the verdict is "decline".
# ---------------------------------------------------------------------------
t17h="$TMP/t17h"; kit "$t17h" cli user .installed-version $CLI_BINS
h17h="$t17h/home"; ch17h="$h17h/.burrowee/cli"; mkdir -p "$ch17h"
seed_ours "$h17h/.local/bin" $CLI_BINS

# THE EXIT CODE IS NOT THE CLAIM HERE. upgrade.sh forces (--assume-below +
# --rerun-recorded), so the rung is RUN whatever its --applies probe thinks and
# the ladder reports 2 for every spelling. What separates a correct run from a
# destructive one is whether the sweep, once running, still recognises the
# directory it is standing in — so the files are the assertion, and the
# destination this run resolved is asserted by NAME so a doubled slash cannot
# hide inside a passing test.
#
# The control comes first: if a canonically spelled PREFIX ever starts eating
# the install, the two cases below prove nothing.
run_upgrade_with_prefix "$t17h" "$h17h" "$ch17h" "$h17h/.local" 0.2.0
assert_eq "$RC" 2 "control: a forced run reports that the rung ran"
assert_contains "$OUT" "shadow $h17h/.local/bin on PATH" "control: the sweep must name the canonical destination"
for b in $CLI_BINS; do
    assert_present "$h17h/.local/bin/$b" "control: the live cli install must survive a forced run"
done

run_upgrade_with_prefix "$t17h" "$h17h" "$ch17h" "$h17h/.local/" 0.2.0
assert_contains "$OUT" "shadow $h17h/.local/bin on PATH" "a trailing-slash PREFIX must resolve to the SAME destination name"
for b in $CLI_BINS; do
    assert_present "$h17h/.local/bin/$b" "a trailing-slash PREFIX must not make the sweep eat the live install"
done

run_upgrade_with_prefix "$t17h" "$h17h" "$ch17h" "$h17h/.local//" 0.2.0
assert_contains "$OUT" "shadow $h17h/.local/bin on PATH" "a doubled-slash PREFIX must resolve to the SAME destination name"
for b in $CLI_BINS; do
    assert_present "$h17h/.local/bin/$b" "a doubled-slash PREFIX must not make the sweep eat the live install"
done

# 17g. the command line: one version, and it must parse.
run_upgrade "$t17" "$h17" "$ch17" "$h17/usr-local-bin"
assert_eq "$RC" 64 "no version is a usage error"
run_upgrade "$t17" "$h17" "$ch17" "$h17/usr-local-bin" 0.2.0 extra
assert_eq "$RC" 64 "a second argument must be rejected, never silently discarded"
run_upgrade "$t17" "$h17" "$ch17" "$h17/usr-local-bin" 0.2.x
assert_eq "$RC" 64 "an unparseable version must be refused, never rounded to 0.2.0"

# 17h. A FLOOR BELOW THE TOP IS THE NORMAL BACKFILL, never a refusal. The
# cross-check in 17d is one-directional: only a floor ABOVE the kit's newest
# target names a migration the kit does not carry. 0.1.0 on this 0.2.0 kit is
# "this host missed the 0.2.0 work" — refusing it (or demanding equality) would
# break the forcing path on the first release whose line moved past a ladder
# that shipped no new rung. The kit's one rung targets 0.2.0 >= 0.1.0, so it is
# selected and runs.
seed_ours "$h17/.local/bin" burrowee-edge
run_upgrade "$t17" "$h17" "$ch17" "$h17/usr-local-bin" 0.1.0
assert_eq "$RC" 2 "a floor BELOW the kit's top is the normal backfill and must run, not be refused"
assert_contains "$OUT" "every rung targeting 0.1.0 or newer will be re-run" "the backfill must announce the floor's selection before running it"
assert_gone "$h17/.local/bin/burrowee-edge" "the 0.2.0 rung is at or above the 0.1.0 floor and must run"
assert_lacks "$OUT" "older rung(s) below the floor" "a ladder with nothing below the floor must not claim it skipped something"

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

# ===========================================================================
# THE ADOPTION RUNG (adopt_user_tree.sh) AND THE STOP IT NEEDS
#
# Everything below is about the rung that carries a pre-collapse per-user tree
# into the tree a root-scheme daemon reads, and about the promise it broke:
# run.sh's header used to say nothing on its ladders needed a stop.
#
# WHAT IS *NOT* TESTED HERE: the copy. That lives in the edge repo's
# internal/adopt, with its own suite and its own mutation run — the refusal on a
# truncated credential, the atomic publish, the never-overwrite rule and the
# enumerated carried set are all proved there. Re-proving them against a shell
# stub would prove only that the stub agrees with itself. What is proved here is
# the rung's own half: which two trees it names, that it runs the cli at all,
# that the daemon is DOWN before it does, and what the runner tells the caller
# afterwards.
# ===========================================================================

# adopt_kit <dir> <comp> <scheme> <version-file> <bins…> — kit(), plus the
# ledger row and the stop declaration a component with the adoption rung has.
# The sweep row stays FIRST, exactly as edge's shipped ledger has it.
adopt_kit() {
    kit "$@"
    _ak_dir="$1"
    printf '# ledger\n0.2.0 stale_user_bins.sh\n0.2.0 adopt_user_tree.sh\n' > "$_ak_dir/migrations/ledger"
    echo 'SERVICE_STOP_RUNGS="adopt_user_tree.sh"' >> "$_ak_dir/migrations/component.conf"
}

# make_cli_stub <bin-dir> <comp> — a stand-in for burrowee-<comp>-cli
# implementing exactly what the rung asks of it: `migrate --help` exits 0, and
# `migrate --from X --home Y` records its argv in $CLI_STUB_LOG and copies the
# two files the cases below look for.
#
# NOT a reimplementation of the verb. The copy here exists only so the ladder
# cases can assert that the destination ENDS UP HOLDING the files rather than
# that the rung reported success — the two came apart on the production host
# this whole rung exists for.
#
# IT ALSO RETIRES THE SOURCE, because that is now part of the same contract: the
# real verb renames the tree it verified to <tree>.bak.<stamp> and prints the new
# path, and a stub that left the source at its live name would let a case assert a
# state the shipped cli never produces.
make_cli_stub() {
    _mcs_dir="$1"; _mcs_comp="$2"
    mkdir -p "$_mcs_dir"
    {
        echo '#!/bin/sh'
        echo "COMP_NAME=$_mcs_comp"
        cat <<'STUB'
echo "$*" >> "${CLI_STUB_LOG:-/dev/null}"
[ "$1" = migrate ] || exit 2
[ "$2" = --help ] && exit 0
FROM=""; ROOT=""; FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --home) ROOT="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) shift ;;
    esac
done
[ -n "$FROM" ] && [ -n "$ROOT" ] || exit 64
DST="$ROOT/$COMP_NAME"
mkdir -p "$DST/identity"
# --force overwrites and SNAPSHOTS FIRST; without it the copy never overwrites.
# The stub mirrors only the contract the RUNG depends on — the real publish,
# refusal and enumerated carried set are proved in the edge repo's internal/adopt.
if [ "$FORCE" = 1 ]; then
    [ -d "$DST" ] && cp -R "$DST" "$DST.pre-force-stub" 2>/dev/null || true
    cp "$FROM/identity/relay_ed.key" "$DST/identity/relay_ed.key" 2>/dev/null || true
    cp "$FROM/config" "$DST/config" 2>/dev/null || true
    echo "cli-stub: REPLACED $DST/identity/relay_ed.key"
else
    [ -f "$DST/identity/relay_ed.key" ] || cp "$FROM/identity/relay_ed.key" "$DST/identity/relay_ed.key" 2>/dev/null || true
    [ -f "$DST/config" ] || cp "$FROM/config" "$DST/config" 2>/dev/null || true
fi
echo "cli-stub: adopted $FROM -> $DST"
# RETIRE THE SOURCE, exactly as the verb does: only after the copy, only when the
# destination actually holds the identity, and by RENAME so every byte survives.
if [ -s "$DST/identity/relay_ed.key" ] && [ -d "$FROM" ]; then
    RETIRED="$FROM.bak.$(date -u +%Y%m%d-%H%M%S)"
    if mv "$FROM" "$RETIRED" 2>/dev/null; then
        echo "cli-stub: retired $FROM -> $RETIRED"
    fi
fi
STUB
    } > "$_mcs_dir/burrowee-$_mcs_comp-cli"
    chmod 0755 "$_mcs_dir/burrowee-$_mcs_comp-cli"
}

# retired_tree <live-path> — the single <live-path>.bak.<stamp> the cli renamed
# that tree to, or "" when there is not exactly one.
#
# A VERIFIED ADOPTION RETIRES ITS SOURCE, so a case that wants to assert the
# source survived asks for the name it survived UNDER. The stamp is the run's own
# instant, so it cannot be written into a fixture; the count is checked here
# because two retired trees would mean the rename ran twice on a ladder that must
# be idempotent, and "" then makes the caller's assert_present fail.
retired_tree() {
    _rt_n=0; _rt_hit=""
    for _rt_p in "$1".bak.*; do
        [ -d "$_rt_p" ] || continue
        _rt_hit="$_rt_p"; _rt_n=$((_rt_n + 1))
    done
    [ "$_rt_n" = 1 ] || _rt_hit=""
    echo "$_rt_hit"
}

# make_supervisor_stub <dir> <mode> — a stand-in for systemctl AND launchctl, so
# the case reads the same on Linux and macOS.
#   kills   reads $STOP_PIDFILE and kills that process (a supervisor that works)
#   inert   logs and does nothing (a container, or a unit that is not loaded)
make_supervisor_stub() {
    mkdir -p "$1"
    make_reachable_sudo "$1"
    {
        echo '#!/bin/sh'
        echo "echo \"\$*\" >> \"$1/supervisor.log\""
        if [ "$2" = kills ]; then
            echo 'if [ -f "${STOP_PIDFILE:-/nonexistent}" ]; then kill "$(cat "$STOP_PIDFILE")" 2>/dev/null || true; fi'
        fi
        echo 'exit 0'
    } > "$1/supervisor"
    chmod 0755 "$1/supervisor"
}

# make_reachable_sudo <dir> — a $SUDO that logs and EXECS its arguments.
#
# The other cases in this suite point $SUDO at /nonexistent-sudo, because the
# sweep must never escalate. The adoption rung is the opposite: it runs as root
# in production and pre-flights `elevate true` precisely so it can refuse BEFORE
# stopping anything when it cannot. Pointing it at a sudo that cannot run would
# make every case below a test of that one refusal — which has its own case (25b)
# — instead of a test of the adoption.
make_reachable_sudo() {
    mkdir -p "$1"
    {
        echo '#!/bin/sh'
        echo "echo \"\$*\" >> \"$1/sudo.log\""
        echo 'exec "$@"'
    } > "$1/sudo"
    chmod 0755 "$1/sudo"
}

# start_fake_daemon <dir> <name> — a REAL running process whose argv[0] is
# <dir>/<name>. Echoes its pid.
#
# ITS STDOUT AND STDERR GO TO /dev/null, and that is not tidiness. This function
# is called inside `$( … )`, and a command substitution does not return until
# every process holding the write end of its pipe has exited — a background child
# that inherits it hangs the whole suite for the sleeper's full lifetime. It cost
# one 600-second timeout to find.
start_fake_daemon() {
    mkdir -p "$1"
    cp "$BINFIX/sleeper.bin" "$1/$2"
    chmod 0755 "$1/$2"
    "$1/$2" >/dev/null 2>&1 &
    echo $!
}

# seed_per_user_tree <dir> — a paired, pre-collapse tree: the identity is the
# evidence the rung keys on, and the config is the file the outage named.
seed_per_user_tree() {
    mkdir -p "$1/identity"
    printf 'PRIVATE-KEY-BYTES\n' > "$1/identity/relay_ed.key"
    printf 'host_fqdn=edge.example.org\ntls_listen=:443\n' > "$1/config"
}

# run_adopt_ladder <kit> <home> <comp-home> <bin-dir> <stub-dir> [args…]
#
# $SUDO_USER is EXPORTED EMPTY unless $ADOPT_SUDO_USER names an account. The
# suite runs under whatever shell an operator started, and a developer who ran
# it from a `sudo -s` would otherwise have every case resolve its source out of
# their real home directory — the one variable that decides which tree this rung
# takes, inherited from the environment. $ADOPT_HOME_PARENTS is its other half:
# the fixture parent a named account's home is resolved under.
# $ADOPT_COMP_DATA is the DATA root a `system`-scheme case names. It is a
# variable rather than a sixth positional so the `user`-scheme cases (cli) can
# leave it unset and keep their one-tree shape — run.sh forces $COMP_DATA to
# $COMP_HOME for every scheme but `system` anyway, so what is passed there is
# irrelevant; what matters is that a system kit ALWAYS names both, because run.sh
# refuses a $COMP_HOME without a $COMP_DATA rather than pairing a named tree with
# a default one.
#
# $ROOT_HOME is seamed for the same reason LAUNCHD_DIR is. It is no longer a
# candidate SOURCE — that is the whole point of case 28 — but it is still where
# a `root`-scheme component's HOME resolves, and an unseamed run would name the
# real /root (or /var/root) on the machine running this suite. Several cases
# below also SEED a tree there, precisely to prove it is never taken.
run_adopt_ladder() {
    _ral_kit="$1"; _ral_home="$2"; _ral_ch="$3"; _ral_bin="$4"; _ral_stub="$5"; shift 5
    CLI_STUB_LOG="$_ral_stub/cli.log"
    OUT="$(
        HOME="$_ral_home" \
        COMP_HOME="$_ral_ch" \
        COMP_DATA="${ADOPT_COMP_DATA:-$_ral_ch}" \
        SYS_CONFIG_ROOT="$_ral_home/sys-etc/burrowee" \
        SYS_DATA_ROOT="$_ral_home/sys-var/burrowee" \
        ROOT_HOME="$_ral_home/root-home" \
        BIN_DIR="$_ral_bin" \
        LAUNCHD_DIR="$_ral_home/no-launchd" \
        SYSTEMD_DIR="$_ral_home/no-systemd" \
        BURROWEE_LEGACY_HOME_PARENTS="${ADOPT_HOME_PARENTS:-$_ral_home/nowhere}" \
        SUDO_USER="${ADOPT_SUDO_USER:-}" \
        SUDO="${ADOPT_SUDO:-$_ral_stub/sudo}" \
        SYSTEMCTL="$_ral_stub/supervisor" \
        LAUNCHCTL="$_ral_stub/supervisor" \
        CLI_STUB_LOG="$CLI_STUB_LOG" \
        STOP_PIDFILE="${STOP_PIDFILE:-}" \
        BURROWEE_MIGRATE_STOP_TIMEOUT="${BURROWEE_MIGRATE_STOP_TIMEOUT:-2}" \
        sh "$_ral_kit/migrations/run.sh" "$@" 2>&1
    )"
    RC=$?
}

# ---------------------------------------------------------------------------
# 22. admin-kr's EXACT STATE, driven through upgrade.sh — the case the rung
#     exists for.
#
#     Per-user tree populated, root tree empty, anchor already reading 0.2.0
#     (so the plain ladder's numeric gate can see nothing), and the operator
#     running `upgrade.sh 0.2.0`, which is run.sh --assume-below 0.2.0
#     --rerun-recorded.
# ---------------------------------------------------------------------------
t22="$TMP/t22"; adopt_kit "$t22" edge system installed-version $EDGE_BINS
h22="$t22/home"; ch22="$h22/sys-etc/burrowee/edge"; cd22="$h22/sys-var/burrowee/edge"; mkdir -p "$ch22" "$cd22"
seed_per_user_tree "$h22/.burrowee/edge"
seed_ours "$h22/usr-local-bin" $EDGE_BINS
make_cli_stub "$h22/usr-local-bin" edge
mkdir -p "$h22/stubs"; make_supervisor_stub "$h22/stubs" kills
echo "0.2.0.2026.08.19.78a2c91a" > "$ch22/installed-version"

# 22a. THE PLAIN LADDER DOES NOTHING — the state the operator is stuck in. The
#      anchor already says 0.2.0, so the numeric gate closes both rows.
ADOPT_COMP_DATA="$cd22" \
run_adopt_ladder "$t22" "$h22" "$ch22" "$h22/usr-local-bin" "$h22/stubs"
assert_eq "$RC" 0 "a 0.2.0 anchor must make the plain ladder a no-op — this is why the host stayed broken"
assert_gone "$ch22/identity/relay_ed.key" "the plain ladder must not have adopted anything"
assert_contains "$OUT" "nothing applied" "the ladder must say it evaluated and declined, not exit silently"
assert_lacks "$OUT" "is STOPPED" "a run that applied nothing may not claim a daemon is down"

# 22b. upgrade.sh forces it. This is the path the operator actually uses.
UPGRADE_OUT="$(
    HOME="$h22" COMP_HOME="$ch22" COMP_DATA="$cd22" BIN_DIR="$h22/usr-local-bin" \
    SYS_CONFIG_ROOT="$h22/sys-etc/burrowee" SYS_DATA_ROOT="$h22/sys-var/burrowee" \
    ROOT_HOME="$h22/root-home" \
    LAUNCHD_DIR="$h22/no-launchd" SYSTEMD_DIR="$h22/no-systemd" \
    BURROWEE_LEGACY_HOME_PARENTS="$h22/nowhere" SUDO="$h22/stubs/sudo" \
    SYSTEMCTL="$h22/stubs/supervisor" LAUNCHCTL="$h22/stubs/supervisor" \
    CLI_STUB_LOG="$h22/stubs/cli.log" BURROWEE_MIGRATE_STOP_TIMEOUT=2 \
    sh "$t22/migrations/upgrade.sh" 0.2.0 2>&1
)"; UPGRADE_RC=$?
assert_eq "$UPGRADE_RC" 2 "upgrade.sh must force the adoption on a 0.2.0-anchored host"
assert_contains "$UPGRADE_OUT" "adopt_user_tree.sh (target 0.2.0)" "upgrade.sh must NAME the rungs before running them"
assert_contains "$UPGRADE_OUT" "will STOP burrowee-edge" "the runner must announce the stop BEFORE the rung runs"
assert_contains "$UPGRADE_OUT" "adopted $h22/.burrowee/edge" "the rung must say which tree it adopted"
# THE DESTINATION ACTUALLY HOLDS THE FILES. "the rung reported adopted" and
# "the daemon will find an identity" are exactly the two statements that came
# apart on the production host, so the report is never the assertion.
assert_present "$ch22/identity/relay_ed.key" "the destination must HOLD the identity, not merely be reported as adopted"
assert_present "$ch22/config" "the destination must hold the config — host_fqdn is the file the outage named"
# COPY, NEVER MOVE — AND THEN RETIRE. The cli copies file by file and, once the
# copy verifies, renames the tree it adopted to <tree>.bak.<stamp>. Every byte is
# still there and recovery is one `mv` back, so the source is asserted at the name
# it now has.
R22="$(retired_tree "$h22/.burrowee/edge")"
assert_gone "$h22/.burrowee/edge" "a verified adoption must not leave the source at its live name"
assert_present "$R22/identity/relay_ed.key" "the per-user tree must survive the retirement — recovery is pointing the old unit back at it"
assert_eq "$(cat "$ch22/config")" "$(cat "$R22/config")" "the adopted config must be the source config"
# THE CLI IS WHAT DID THE COPY, with both trees named.
assert_contains "$(cat "$h22/stubs/cli.log")" "migrate --from $h22/.burrowee/edge --home $h22/sys-etc/burrowee" "the rung must exec the cli with the source tree and the destination ROOT"
# AND THE CALLER IS TOLD THE DAEMON IS DOWN.
assert_contains "$UPGRADE_OUT" "burrowee-edge is STOPPED" "the runner's last line must say the daemon is stopped"
assert_contains "$UPGRADE_OUT" "read the runner's last line above" "upgrade.sh, which starts nothing, must point the operator at it"
assert_present "$ch22/migration-receipts/adopt_user_tree.sh@0.2.0.done" "the runner must record the rung"

# 22c. IDEMPOTENT, and honest about it: the receipt skips it, and the closing
#      line goes back to saying nothing was stopped.
ADOPT_COMP_DATA="$cd22" \
run_adopt_ladder "$t22" "$h22" "$ch22" "$h22/usr-local-bin" "$h22/stubs"
assert_eq "$RC" 0 "a second plain run must be a clean no-op"
assert_contains "$OUT" "nothing applied" "the second run must decline on the receipt and say so"
assert_lacks "$OUT" "is STOPPED" "nothing may claim the daemon is down on a run that ran nothing"

# ---------------------------------------------------------------------------
# 23. THE --applies BLINDNESS ASYMMETRY. Adoption applies when it CANNOT TELL.
#
#     Both pieces of evidence sit in 0700 trees — the destination is root's, the
#     source is the operator's — and the probe is reached unprivileged all the
#     time, because install.sh and update.sh run the runner as the invoking user.
#     A probe that read "I could not see" as "already done" would skip the
#     migration on precisely the hosts it exists for, silently.
# ---------------------------------------------------------------------------
if [ "$(id -u)" = 0 ]; then
    fail "case 23 must not run as root: chmod 000 does not blind uid 0, so every
      blindness assertion below would pass without measuring anything. Re-run
      this suite as an unprivileged user."
else

# 23a. THE DESTINATION IS UNREADABLE and root is unreachable → still needed.
t23="$TMP/t23"; adopt_kit "$t23" edge system installed-version $EDGE_BINS
h23="$t23/home"; ch23="$h23/sys-etc/burrowee/edge"; cd23="$h23/sys-var/burrowee/edge"; mkdir -p "$ch23/identity"
seed_per_user_tree "$h23/.burrowee/edge"
seed_ours "$h23/usr-local-bin" $EDGE_BINS
make_cli_stub "$h23/usr-local-bin" edge
mkdir -p "$h23/stubs"; make_supervisor_stub "$h23/stubs" kills
# The destination HAS an identity — so a probe that could read it would say "no".
printf 'ALREADY-ADOPTED\n' > "$ch23/identity/relay_ed.key"
chmod 000 "$ch23/identity"
# The blindfold is asserted, not assumed. If this file were readable the case
# below would be measuring the readable-presence path instead.
if [ -r "$ch23/identity/relay_ed.key" ]; then
    fail "case 23a fixture is readable — the blindness assertion would prove nothing"
fi
ADOPT_COMP_DATA="$cd23" \
run_adopt_ladder "$t23" "$h23" "$ch23" "$h23/usr-local-bin" "$h23/stubs"
assert_eq "$RC" 2 "an unreadable destination must answer STILL NEEDED, never 'already done'"
assert_contains "$OUT" "adopt_user_tree.sh applies: no recorded version" "the probe must select the rung when it cannot see"
chmod 700 "$ch23/identity"

# 23b. THE SAME DESTINATION, NOW READABLE, holding an identity → does NOT apply.
#      This is the other half: without it, "always answers yes" would pass 23a.
t23b="$TMP/t23b"; adopt_kit "$t23b" edge system installed-version $EDGE_BINS
h23b="$t23b/home"; ch23b="$h23b/sys-etc/burrowee/edge"; cd23b="$h23b/sys-var/burrowee/edge"; mkdir -p "$ch23b/identity"
seed_per_user_tree "$h23b/.burrowee/edge"
seed_ours "$h23b/usr-local-bin" $EDGE_BINS
make_cli_stub "$h23b/usr-local-bin" edge
mkdir -p "$h23b/stubs"; make_supervisor_stub "$h23b/stubs" kills
printf 'ALREADY-ADOPTED\n' > "$ch23b/identity/relay_ed.key"
ADOPT_COMP_DATA="$cd23b" \
run_adopt_ladder "$t23b" "$h23b" "$ch23b" "$h23b/usr-local-bin" "$h23b/stubs"
assert_contains "$OUT" "adopt_user_tree.sh skipped: no recorded version" "a READABLE identity at the destination is positive evidence the rung has run"
assert_eq "$(cat "$ch23b/identity/relay_ed.key")" "ALREADY-ADOPTED" "an already-adopted destination must not be touched"

# 23c. THE SOURCE IS UNREADABLE → still needed. The same asymmetry facing the
#      other way: "I cannot read the operator's 0700 tree" and "there is nothing
#      in it" are what a bare `-s` cannot tell apart, and reading the second as
#      the first skips the rung on the host that has the state.
t23c="$TMP/t23c"; adopt_kit "$t23c" edge system installed-version $EDGE_BINS
h23c="$t23c/home"; ch23c="$h23c/sys-etc/burrowee/edge"; cd23c="$h23c/sys-var/burrowee/edge"; mkdir -p "$ch23c" "$cd23c"
seed_per_user_tree "$h23c/.burrowee/edge"
seed_ours "$h23c/usr-local-bin" $EDGE_BINS
make_cli_stub "$h23c/usr-local-bin" edge
mkdir -p "$h23c/stubs"; make_supervisor_stub "$h23c/stubs" kills
chmod 000 "$h23c/.burrowee/edge/identity"
if [ -r "$h23c/.burrowee/edge/identity/relay_ed.key" ]; then
    fail "case 23c fixture is readable — the blindness assertion would prove nothing"
fi
OUT="$(HOME="$h23c" COMP_HOME="$ch23c" COMP_DATA="$cd23c" BIN_DIR="$h23c/usr-local-bin" \
    ROOT_HOME="$h23c/root-home" \
    BURROWEE_LEGACY_HOME_PARENTS="$h23c/nowhere" SUDO=/nonexistent-sudo \
    sh "$t23c/migrations/adopt_user_tree.sh" --applies 2>&1)"; RC=$?
assert_eq "$RC" 0 "an unreadable SOURCE must answer STILL NEEDED, never 'nothing to adopt'"
chmod 700 "$h23c/.burrowee/edge/identity"

# 23d. A PER-USER TREE WITH NO IDENTITY, fully readable → does NOT apply. An
#      unenrolled tree has nothing to carry, and claiming otherwise would leave a
#      misleading receipt on every fresh host.
t23d="$TMP/t23d"; adopt_kit "$t23d" edge system installed-version $EDGE_BINS
h23d="$t23d/home"; ch23d="$h23d/sys-etc/burrowee/edge"; cd23d="$h23d/sys-var/burrowee/edge"; mkdir -p "$ch23d" "$cd23d" "$h23d/.burrowee/edge"
OUT="$(HOME="$h23d" COMP_HOME="$ch23d" COMP_DATA="$cd23d" BIN_DIR="$h23d/usr-local-bin" \
    ROOT_HOME="$h23d/root-home" \
    BURROWEE_LEGACY_HOME_PARENTS="$h23d/nowhere" SUDO=/nonexistent-sudo \
    sh "$t23d/migrations/adopt_user_tree.sh" --applies 2>&1)"; RC=$?
assert_eq "$RC" 1 "an unenrolled per-user tree has nothing to adopt"

fi   # not root

# ---------------------------------------------------------------------------
# 24. THE STOP IS A POST-CONDITION, NOT A REQUEST.
#
#     A daemon that is still up after the supervisor was asked to stop it is a
#     daemon that is still WRITING: burrowee-edge mints identity/relay_ed.key and
#     bridge/bridge_ed.key when it cannot find them, and the copy never
#     overwrites, so the minted keys win. The rung must refuse rather than copy
#     into a moving tree.
# ---------------------------------------------------------------------------
t24="$TMP/t24"; adopt_kit "$t24" edge system installed-version $EDGE_BINS
h24="$t24/home"; ch24="$h24/sys-etc/burrowee/edge"; cd24="$h24/sys-var/burrowee/edge"; mkdir -p "$ch24" "$cd24" "$h24/stubs"
seed_per_user_tree "$h24/.burrowee/edge"
seed_ours "$h24/usr-local-bin" $EDGE_BINS
make_cli_stub "$h24/usr-local-bin" edge
make_supervisor_stub "$h24/stubs" inert          # a supervisor that cannot stop it
D24_PID="$(start_fake_daemon "$h24/daemon" burrowee-edge)"
printf '{"pid": %s, "version": "0.2.0"}\n' "$D24_PID" > "$ch24/running.json"
STOP_PIDFILE=""; export STOP_PIDFILE
ADOPT_COMP_DATA="$cd24" \
run_adopt_ladder "$t24" "$h24" "$ch24" "$h24/usr-local-bin" "$h24/stubs"
assert_eq "$RC" 1 "a daemon still running after the stop must FAIL the rung, not be copied under"
assert_contains "$OUT" "REFUSING to copy into" "the refusal must say what it refused and why"
assert_gone "$ch24/identity/relay_ed.key" "nothing may be copied into a tree a daemon is still writing"
assert_eq "$(cat "$h24/stubs/cli.log" 2>/dev/null | grep -c '^migrate --from' || true)" "0" "the cli must never be exec'd once the stop failed"
assert_present "$h24/.burrowee/edge/identity/relay_ed.key" "the per-user tree is untouched by a refusal"
kill "$D24_PID" 2>/dev/null || true

# 24b. THE SAME FIXTURE WITH A SUPERVISOR THAT WORKS — the rung proceeds.
#      This is what makes 24 an assertion about the STOP rather than about
#      "there was a running.json": right and wrong would otherwise produce the
#      same refusal.
t24b="$TMP/t24b"; adopt_kit "$t24b" edge system installed-version $EDGE_BINS
h24b="$t24b/home"; ch24b="$h24b/sys-etc/burrowee/edge"; cd24b="$h24b/sys-var/burrowee/edge"; mkdir -p "$ch24b" "$cd24b" "$h24b/stubs"
seed_per_user_tree "$h24b/.burrowee/edge"
seed_ours "$h24b/usr-local-bin" $EDGE_BINS
make_cli_stub "$h24b/usr-local-bin" edge
make_supervisor_stub "$h24b/stubs" kills
D24B_PID="$(start_fake_daemon "$h24b/daemon" burrowee-edge)"
printf '{"pid": %s, "version": "0.2.0"}\n' "$D24B_PID" > "$ch24b/running.json"
STOP_PIDFILE="$h24b/daemon.pid"; echo "$D24B_PID" > "$STOP_PIDFILE"; export STOP_PIDFILE
ADOPT_COMP_DATA="$cd24b" \
run_adopt_ladder "$t24b" "$h24b" "$ch24b" "$h24b/usr-local-bin" "$h24b/stubs"
assert_eq "$RC" 2 "with the daemon actually stopped the rung must proceed"
assert_present "$ch24b/identity/relay_ed.key" "and the identity must land"
assert_contains "$(cat "$h24b/stubs/supervisor.log")" "stop burrowee-edge" "the stop must go through the supervisor seam"
assert_lacks "$(cat "$h24b/stubs/supervisor.log")" "burrowee-edge-updater" "the UPDATER must never be stopped — update.sh runs under it"
STOP_PIDFILE=""; export STOP_PIDFILE
kill "$D24B_PID" 2>/dev/null || true

# 24c. A RUNNING burrowee-edge-updater IS NOT THE DAEMON. The liveness pattern
#      terminates, so a longer basename does not match — without this the rung
#      would refuse forever on every host that runs an updater, which is all of
#      the ones that take a push update.
t24c="$TMP/t24c"; adopt_kit "$t24c" edge system installed-version $EDGE_BINS
h24c="$t24c/home"; ch24c="$h24c/sys-etc/burrowee/edge"; cd24c="$h24c/sys-var/burrowee/edge"; mkdir -p "$ch24c" "$cd24c" "$h24c/stubs"
seed_per_user_tree "$h24c/.burrowee/edge"
seed_ours "$h24c/usr-local-bin" $EDGE_BINS
make_cli_stub "$h24c/usr-local-bin" edge
make_supervisor_stub "$h24c/stubs" inert
D24C_PID="$(start_fake_daemon "$h24c/daemon" burrowee-edge-updater)"
printf '{"pid": %s, "version": "0.2.0"}\n' "$D24C_PID" > "$ch24c/running.json"
ADOPT_COMP_DATA="$cd24c" \
run_adopt_ladder "$t24c" "$h24c" "$ch24c" "$h24c/usr-local-bin" "$h24c/stubs"
assert_eq "$RC" 2 "a running burrowee-edge-updater must not read as a live burrowee-edge"
assert_present "$ch24c/identity/relay_ed.key" "and the adoption must proceed"
kill "$D24C_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 25. EVERY PRE-FLIGHT RUNS BEFORE THE STOP. Discovering a missing cli after the
#     daemon is down turns a refusal that cost nothing into an outage, on a host
#     that is mid-upgrade with freshly swapped binaries.
# ---------------------------------------------------------------------------
t25="$TMP/t25"; adopt_kit "$t25" edge system installed-version $EDGE_BINS
h25="$t25/home"; ch25="$h25/sys-etc/burrowee/edge"; cd25="$h25/sys-var/burrowee/edge"; mkdir -p "$ch25" "$cd25" "$h25/stubs" "$h25/usr-local-bin"
seed_per_user_tree "$h25/.burrowee/edge"
make_supervisor_stub "$h25/stubs" kills
D25_PID="$(start_fake_daemon "$h25/daemon" burrowee-edge)"
printf '{"pid": %s, "version": "0.2.0"}\n' "$D25_PID" > "$ch25/running.json"
STOP_PIDFILE="$h25/daemon.pid"; echo "$D25_PID" > "$STOP_PIDFILE"; export STOP_PIDFILE
ADOPT_COMP_DATA="$cd25" \
run_adopt_ladder "$t25" "$h25" "$ch25" "$h25/usr-local-bin" "$h25/stubs"
assert_eq "$RC" 1 "no cli in \$BIN_DIR must fail the rung"
assert_contains "$OUT" "nothing has been stopped" "the refusal must say the daemon was left alone"
assert_lacks "$(cat "$h25/stubs/supervisor.log" 2>/dev/null || echo "")" "stop" "the supervisor must not have been asked to stop anything"
if ! kill -0 "$D25_PID" 2>/dev/null; then
    fail "case 25: the daemon was stopped before the pre-flight refused"
fi
CASES=$((CASES + 1))
STOP_PIDFILE=""; export STOP_PIDFILE
kill "$D25_PID" 2>/dev/null || true

# 25b. THE OTHER PRE-FLIGHT: root is not reachable. On the console-push path
#      $SUDO carries -n and there is no terminal to prompt on, so this is a real
#      state rather than a hypothetical — and finding it out after the daemon is
#      down is an outage where a refusal costs nothing.
t25b="$TMP/t25b"; adopt_kit "$t25b" edge system installed-version $EDGE_BINS
h25b="$t25b/home"; ch25b="$h25b/sys-etc/burrowee/edge"; cd25b="$h25b/sys-var/burrowee/edge"; mkdir -p "$ch25b" "$cd25b" "$h25b/stubs"
seed_per_user_tree "$h25b/.burrowee/edge"
seed_ours "$h25b/usr-local-bin" $EDGE_BINS
make_cli_stub "$h25b/usr-local-bin" edge
make_supervisor_stub "$h25b/stubs" kills
D25B_PID="$(start_fake_daemon "$h25b/daemon" burrowee-edge)"
printf '{"pid": %s, "version": "0.2.0"}\n' "$D25B_PID" > "$ch25b/running.json"
STOP_PIDFILE="$h25b/daemon.pid"; echo "$D25B_PID" > "$STOP_PIDFILE"; export STOP_PIDFILE
ADOPT_COMP_DATA="$cd25b" \
ADOPT_SUDO=/nonexistent-sudo run_adopt_ladder "$t25b" "$h25b" "$ch25b" "$h25b/usr-local-bin" "$h25b/stubs"
assert_eq "$RC" 1 "an unreachable root must fail the rung"
assert_contains "$OUT" "cannot reach root" "the refusal must name the cause"
assert_contains "$OUT" "nothing has been stopped" "and say the daemon was left alone"
if ! kill -0 "$D25B_PID" 2>/dev/null; then
    fail "case 25b: the daemon was stopped before the elevation pre-flight refused"
fi
CASES=$((CASES + 1))
STOP_PIDFILE=""; export STOP_PIDFILE
kill "$D25B_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 26. THE cli COMPONENT IS UNCHANGED BY ALL OF THIS.
#
#     The runner is shared. adopt_user_tree.sh is staged into cli's kit too,
#     because payload.sh globs the shared directory — so "cli is unaffected" is a
#     claim about what its LEDGER and its component.conf say, and it is asserted
#     rather than assumed.
# ---------------------------------------------------------------------------
t26="$TMP/t26"; kit "$t26" cli user .installed-version $CLI_BINS
h26="$t26/home"; ch26="$h26/.burrowee/cli"; mkdir -p "$ch26" "$h26/stubs"
seed_ours "$h26/.local/bin" $CLI_BINS
seed_twins "$h26/usr-local-bin" $CLI_BINS
make_supervisor_stub "$h26/stubs" kills
assert_present "$t26/migrations/adopt_user_tree.sh" "the shared rung IS staged into cli's kit — that is what makes this case necessary"
run_adopt_ladder "$t26" "$h26" "$ch26" "$h26/usr-local-bin" "$h26/stubs"
assert_eq "$RC" 2 "cli's ladder still runs its sweep exactly as before"
assert_contains "$OUT" "no service was stopped, so there is nothing to start" "a component that declares no stop rung gets the unchanged closing line"
assert_lacks "$OUT" "will STOP" "nothing may announce a stop on a ladder that declares none"
assert_lacks "$OUT" "is STOPPED" "and nothing may claim one afterwards"
assert_lacks "$(cat "$h26/stubs/supervisor.log" 2>/dev/null || echo "")" "stop" "cli's ladder must not touch any supervisor"

# 26b. upgrade.sh's exit-2 sentence for cli is the one it always was, VERBATIM.
UPGRADE_OUT="$(
    HOME="$h26" COMP_HOME="$ch26" BIN_DIR="$h26/usr-local-bin" \
    LAUNCHD_DIR="$h26/no-launchd" SYSTEMD_DIR="$h26/no-systemd" \
    BURROWEE_LEGACY_HOME_PARENTS="$h26/nowhere" SUDO=/nonexistent-sudo \
    sh "$t26/migrations/upgrade.sh" 0.2.0 2>&1
)"
assert_contains "$UPGRADE_OUT" "This ladder stops no service, so there is" "cli's operator override must still say nothing was left down"
assert_lacks "$UPGRADE_OUT" "read the runner's last line above" "and must not send a cli operator looking for a stop that cannot happen"

# 26c. AND IF A user-SCHEME COMPONENT EVER DID NAME THE RUNG, it is inert: its
#      operator tree IS its component tree, so there is nothing to adopt and the
#      rung says so instead of copying a tree onto itself. This is the
#      "does cli need an adoption rung?" question, answered in the suite.
t26c="$TMP/t26c"; adopt_kit "$t26c" cli user .installed-version $CLI_BINS
h26c="$t26c/home"; ch26c="$h26c/.burrowee/cli"; mkdir -p "$ch26c/identity" "$h26c/stubs"
# The component tree holds an identity, which is what makes the guard OBSERVABLE:
# with it, the tree is skipped as a candidate and the rung reports no source at
# all; without it, the same directory is selected as its own source. An empty
# tree produces the same output either way and would test nothing.
printf 'PRIVATE-KEY-BYTES\n' > "$ch26c/identity/relay_ed.key"
seed_ours "$h26c/.local/bin" $CLI_BINS
seed_twins "$h26c/usr-local-bin" $CLI_BINS
make_supervisor_stub "$h26c/stubs" kills
# --installed-version forces the gate: the probe DOES decline here (which is
# itself correct — there is nothing to adopt), and the point of this case is what
# the rung does when it is made to run anyway.
run_adopt_ladder "$t26c" "$h26c" "$ch26c" "$h26c/usr-local-bin" "$h26c/stubs" --installed-version 0.0.0
assert_contains "$OUT" "no enrolled identity in" "a per-user component's tree IS its component tree, so it must be skipped as a CANDIDATE and the rung must report no source at all"
assert_lacks "$OUT" "is one of this component's own trees" "the tree must never be selected and then rejected — it must never be a candidate"
assert_lacks "$(cat "$h26c/stubs/supervisor.log" 2>/dev/null || echo "")" "stop" "and it must stop nothing on the way to saying it"

# ---------------------------------------------------------------------------
# 27. THE STOP DECLARATION IS CROSS-CHECKED AGAINST THE LEDGER.
#
#     $SERVICE_STOP_RUNGS is the only part of this contract that is a claim
#     rather than an observation, and the failure mode of a claim is a typo —
#     which is silent in the worst way: the rung still stops the daemon, the
#     announcement never prints, and exit 2 tells the caller everything is up.
# ---------------------------------------------------------------------------
t27="$TMP/t27"; adopt_kit "$t27" edge system installed-version $EDGE_BINS
h27="$t27/home"; ch27="$h27/sys-etc/burrowee/edge"; cd27="$h27/sys-var/burrowee/edge"; mkdir -p "$ch27" "$cd27" "$h27/stubs"
seed_per_user_tree "$h27/.burrowee/edge"
seed_ours "$h27/usr-local-bin" $EDGE_BINS
make_cli_stub "$h27/usr-local-bin" edge
make_supervisor_stub "$h27/stubs" kills
sed -e 's/SERVICE_STOP_RUNGS="adopt_user_tree.sh"/SERVICE_STOP_RUNGS="adopt_user_treee.sh"/' \
    "$t27/migrations/component.conf" > "$t27/migrations/component.conf.new"
mv "$t27/migrations/component.conf.new" "$t27/migrations/component.conf"
ADOPT_COMP_DATA="$cd27" \
run_adopt_ladder "$t27" "$h27" "$ch27" "$h27/usr-local-bin" "$h27/stubs"
assert_eq "$RC" 1 "a SERVICE_STOP_RUNGS name that is not in the ledger must refuse the whole run"
assert_contains "$OUT" "is not a script in" "the refusal must name the value it could not reconcile"
assert_gone "$ch27/identity/relay_ed.key" "and nothing may have been touched"

# ===========================================================================
# 28. ONE SOURCE: THE RUNNING USER'S HOME.
#
#     There used to be two candidates here, root's home first, and that
#     precedence took an edge node down. Everything below is the rule that
#     replaced it: root's home is not a source, whatever it holds; a root login
#     shell has no running user and REFUSES; $ADOPT_FROM still names the tree.
#
#     Every fixture that has a root tree at all seeds it with DIFFERENT BYTES
#     from the running user's, on purpose: two identical trees make the choice
#     between them unobservable, and a case built on identical fixtures would
#     pass for an implementation that took either one.
# ===========================================================================

# seed_tree <dir> <fqdn> — an enrolled tree whose CONTENT identifies it, so an
# assertion can say WHICH tree was adopted rather than that something was.
seed_tree() {
    mkdir -p "$1/identity"
    printf 'PRIVATE-KEY-BYTES-%s\n' "$2" > "$1/identity/relay_ed.key"
    printf 'host_fqdn=%s\ntls_listen=:443\n' "$2" > "$1/config"
}

# seed_stub_tree <dir> — admin-kr's ROOT tree, verbatim in shape: enrolled, and
# a config two days of a crash-looping daemon had rewritten down to ONE line.
# This is the tree the old precedence called "strictly newer".
seed_stub_tree() {
    mkdir -p "$1/identity"
    printf 'PRIVATE-KEY-BYTES-roots-manual-copy\n' > "$1/identity/relay_ed.key"
    printf 'lan_listen=127.0.0.1:9448\n' > "$1/config"
}

# seed_real_tree <dir> — admin-kr's OPERATOR tree: the same identity question,
# the whole five-line answer. tls_listen is the line whose absence made the
# daemon try to bind privileged :443 unprivileged.
seed_real_tree() {
    mkdir -p "$1/identity"
    printf 'PRIVATE-KEY-BYTES-the-operators-tree\n' > "$1/identity/relay_ed.key"
    printf 'tls_listen=127.0.0.1:9443\nlan_listen=127.0.0.1:9448\nserve_mode=frontier\nallow_push_update=true\nhost_fqdn=admin-kr.faranow.com\n' > "$1/config"
}

# make_root_id_stub <dir> — an `id` that answers 0 to `id -u` and defers
# everything else to the real one. It is how a ROOT LOGIN SHELL is reachable
# from an unprivileged suite: euid is the single input that separates "$HOME is
# the running user's" from "$HOME is root's and there is no running user", and a
# case that could only be exercised under sudo would be exercised never.
make_root_id_stub() {
    mkdir -p "$1"
    {
        echo '#!/bin/sh'
        echo '[ "$1" = "-u" ] && { echo 0; exit 0; }'
        echo 'exec /usr/bin/id "$@"'
    } > "$1/id"
    chmod 0755 "$1/id"
}

# 28a. admin-kr's EXACT STATE, and the case the whole rewrite exists for.
#
#      Root's home is enrolled AND holds the one-line stub. The running user's
#      is enrolled and holds the real five-line config. The old rule took root's
#      because it "provably holds an identity" and was tried first; the identity
#      came across fine and the config was destroyed. The FULL config must land.
t28a="$TMP/t28a"; adopt_kit "$t28a" edge system installed-version $EDGE_BINS
h28a="$t28a/home"; ch28a="$h28a/sys-etc/burrowee/edge"; cd28a="$h28a/sys-var/burrowee/edge"
mkdir -p "$ch28a" "$cd28a" "$h28a/stubs"
seed_stub_tree "$h28a/root-home/.burrowee/edge"
seed_real_tree "$h28a/.burrowee/edge"
if cmp -s "$h28a/root-home/.burrowee/edge/config" "$h28a/.burrowee/edge/config"; then
    fail "case 28a fixture: the two trees are byte-identical, so which one was taken is unobservable"
fi
seed_ours "$h28a/usr-local-bin" $EDGE_BINS
make_cli_stub "$h28a/usr-local-bin" edge
make_supervisor_stub "$h28a/stubs" kills
ADOPT_COMP_DATA="$cd28a" \
run_adopt_ladder "$t28a" "$h28a" "$ch28a" "$h28a/usr-local-bin" "$h28a/stubs" --installed-version 0.0.0
assert_eq "$RC" 2 "the running user's tree holds the identity and must be adopted"
assert_contains "$OUT" "adopted $h28a/.burrowee/edge" "the run must name the tree it took"
assert_lacks "$OUT" "$h28a/root-home/.burrowee/edge" "root's home must not even be NAMED — it is not a candidate"
# THE BYTES DECIDE. This is the assertion the differing fixtures exist for, and
# the one the shipped rung fails: the config that lands must be the operator's
# five lines, not root's one.
assert_eq "$(cat "$ch28a/config")" "tls_listen=127.0.0.1:9443
lan_listen=127.0.0.1:9448
serve_mode=frontier
allow_push_update=true
host_fqdn=admin-kr.faranow.com" "the adopted config must be the RUNNING USER's five-line config, not root's one-line stub"
assert_eq "$(cat "$ch28a/identity/relay_ed.key")" "PRIVATE-KEY-BYTES-the-operators-tree" "and the adopted identity must be the running user's"
R28A="$(retired_tree "$h28a/.burrowee/edge")"
assert_present "$R28A/identity/relay_ed.key" "copy never move — the source survives, under the name the retirement gave it"
assert_present "$h28a/root-home/.burrowee/edge/identity/relay_ed.key" "and root's tree is untouched"

# 28b. ONLY ROOT'S HOME IS ENROLLED, and that is NOTHING TO ADOPT.
#
#      The running user's tree is readable and holds no identity, so the answer
#      is provable: there is nothing to carry. Root's enrolled tree does not
#      change it — a rung that fell back to root's here is the one that shipped.
t28b="$TMP/t28b"; adopt_kit "$t28b" edge system installed-version $EDGE_BINS
h28b="$t28b/home"; ch28b="$h28b/sys-etc/burrowee/edge"; cd28b="$h28b/sys-var/burrowee/edge"
mkdir -p "$ch28b" "$cd28b" "$h28b/stubs" "$h28b/.burrowee/edge"
seed_tree "$h28b/root-home/.burrowee/edge" root.example.org
seed_ours "$h28b/usr-local-bin" $EDGE_BINS
make_cli_stub "$h28b/usr-local-bin" edge
make_supervisor_stub "$h28b/stubs" kills
ADOPT_COMP_DATA="$cd28b" \
run_adopt_ladder "$t28b" "$h28b" "$ch28b" "$h28b/usr-local-bin" "$h28b/stubs" --installed-version 0.0.0
assert_contains "$OUT" "nothing to adopt" "and the rung must say so"
assert_gone "$ch28b/identity/relay_ed.key" "nothing may have been copied from root's tree"
assert_eq "$(cat "$h28b/stubs/cli.log" 2>/dev/null | grep -c '^migrate --from' || true)" "0" "the cli must never be exec'd for a tree that is not a candidate"
assert_lacks "$(cat "$h28b/stubs/supervisor.log" 2>/dev/null || echo "")" "stop" "and nothing may be stopped on the way to saying it"

# 28c. $ADOPT_FROM OVERRIDES THE SELECTION ENTIRELY, even with both other trees
#      present and enrolled. The operator has named the tree; a rung that then
#      went looking for a "better" one would be second-guessing the person
#      recovering the host.
t28c="$TMP/t28c"; adopt_kit "$t28c" edge system installed-version $EDGE_BINS
h28c="$t28c/home"; ch28c="$h28c/sys-etc/burrowee/edge"; cd28c="$h28c/sys-var/burrowee/edge"
mkdir -p "$ch28c" "$cd28c" "$h28c/stubs"
seed_tree "$h28c/root-home/.burrowee/edge" root.example.org
seed_tree "$h28c/.burrowee/edge" operator.example.org
seed_tree "$h28c/elsewhere/.burrowee/edge" third.example.org
seed_ours "$h28c/usr-local-bin" $EDGE_BINS
make_cli_stub "$h28c/usr-local-bin" edge
make_supervisor_stub "$h28c/stubs" kills
ADOPT_FROM="$h28c/elsewhere/.burrowee/edge" ADOPT_COMP_DATA="$cd28c" \
run_adopt_ladder "$t28c" "$h28c" "$ch28c" "$h28c/usr-local-bin" "$h28c/stubs" --installed-version 0.0.0
assert_eq "$RC" 2 "ADOPT_FROM must be honoured"
assert_eq "$(cat "$ch28c/config")" "host_fqdn=third.example.org
tls_listen=:443" "ADOPT_FROM must win over the running user's tree, not be merged with it"

# 28d. THE RUNNING USER'S TREE IS READABLE AND HOLDS NO IDENTITY → nothing to
#      adopt. This is the fresh 0.2.x host, and a rung that claimed to apply here
#      would leave a misleading receipt on every one of them.
t28d="$TMP/t28d"; adopt_kit "$t28d" edge system installed-version $EDGE_BINS
h28d="$t28d/home"; ch28d="$h28d/sys-etc/burrowee/edge"; cd28d="$h28d/sys-var/burrowee/edge"
mkdir -p "$ch28d" "$cd28d" "$h28d/stubs" "$h28d/.burrowee"
seed_ours "$h28d/usr-local-bin" $EDGE_BINS
make_cli_stub "$h28d/usr-local-bin" edge
make_supervisor_stub "$h28d/stubs" kills
OUT="$(HOME="$h28d" COMP_HOME="$ch28d" COMP_DATA="$cd28d" ROOT_HOME="$h28d/root-home" \
    BIN_DIR="$h28d/usr-local-bin" BURROWEE_LEGACY_HOME_PARENTS="$h28d/nowhere" SUDO=/nonexistent-sudo \
    sh "$t28d/migrations/adopt_user_tree.sh" --applies 2>&1)"; RC=$?
assert_eq "$RC" 1 "a readable tree with no identity is 'nothing to adopt', not 'still needed'"

# 28e. A ROOT LOGIN SHELL REFUSES, and names $ADOPT_FROM.
#
#      $SUDO_USER unset with euid 0 means no account invoked this run, so there
#      is no running user and no source. $HOME is root's — one keystroke from
#      being taken as the answer, which is exactly the defect. The refusal is
#      asserted DIRECTLY: "it did not use root's home" would also pass for a run
#      that used nothing at all and quietly no-opped.
#
#      Root's tree is seeded ENROLLED so the refusal is measured against a host
#      that visibly has something a fallback would have grabbed.
t28e="$TMP/t28e"; adopt_kit "$t28e" edge system installed-version $EDGE_BINS
h28e="$t28e/home"; ch28e="$h28e/sys-etc/burrowee/edge"; cd28e="$h28e/sys-var/burrowee/edge"
mkdir -p "$ch28e" "$cd28e" "$h28e/stubs"
seed_stub_tree "$h28e/root-home/.burrowee/edge"
seed_ours "$h28e/usr-local-bin" $EDGE_BINS
make_cli_stub "$h28e/usr-local-bin" edge
make_supervisor_stub "$h28e/stubs" kills
make_root_id_stub "$h28e/root-id"
# The blindfold is asserted, not assumed: without the stub this is an ordinary
# unprivileged run and the case would be measuring the wrong branch.
if [ "$(PATH="$h28e/root-id:$PATH" id -u)" != 0 ]; then
    fail "case 28e: the id stub does not answer 0, so the root-login branch is never reached"
fi
OUT="$(PATH="$h28e/root-id:$PATH" HOME="$h28e/root-home" \
    COMP_HOME="$ch28e" COMP_DATA="$cd28e" ROOT_HOME="$h28e/root-home" \
    BIN_DIR="$h28e/usr-local-bin" BURROWEE_LEGACY_HOME_PARENTS="$h28e/nowhere" \
    SUDO="$h28e/stubs/sudo" SYSTEMCTL="$h28e/stubs/supervisor" LAUNCHCTL="$h28e/stubs/supervisor" \
    CLI_STUB_LOG="$h28e/stubs/cli.log" \
    sh "$t28e/migrations/adopt_user_tree.sh" 2>&1)"; RC=$?
assert_eq "$RC" 1 "a root login shell must REFUSE — there is no running user, so there is no source"
assert_contains "$OUT" "REFUSING" "the refusal must say it is one"
assert_contains "$OUT" "ADOPT_FROM=" "and name the escape hatch"
assert_contains "$OUT" "nothing has been stopped" "and say the daemon was left alone"
assert_gone "$ch28e/identity/relay_ed.key" "root's home must not have been adopted"
assert_eq "$(cat "$h28e/stubs/cli.log" 2>/dev/null | grep -c '^migrate --from' || true)" "0" "the cli must never be exec'd"
assert_lacks "$(cat "$h28e/stubs/supervisor.log" 2>/dev/null || echo "")" "stop" "and nothing may be stopped before the refusal"

# 28f. THE SAME ROOT LOGIN SHELL, ASKED --applies, answers STILL NEEDED.
#      The refusal belongs to the run, not to the probe: run.sh reads exit 1 as
#      "does not apply", so refusing there would skip the rung silently on
#      exactly the host that cannot resolve its own source.
OUT="$(PATH="$h28e/root-id:$PATH" HOME="$h28e/root-home" \
    COMP_HOME="$ch28e" COMP_DATA="$cd28e" ROOT_HOME="$h28e/root-home" \
    BIN_DIR="$h28e/usr-local-bin" BURROWEE_LEGACY_HOME_PARENTS="$h28e/nowhere" SUDO=/nonexistent-sudo \
    sh "$t28e/migrations/adopt_user_tree.sh" --applies 2>&1)"; RC=$?
assert_eq "$RC" 0 "no running user is 'I could not be told which tree', which is STILL NEEDED, never 'nothing to adopt'"

# 28h. UNDER sudo THE RUNNING USER IS $SUDO_USER, NOT $HOME.
#
#      This is the documented install path — `curl … | sudo sh` — where $HOME is
#      root's and the tree that matters belongs to the account that typed sudo.
#      $HOME is seeded with a DIFFERENT enrolled tree on purpose: with only one
#      tree in the fixture, "resolved $SUDO_USER" and "fell back to $HOME" would
#      produce the same result and this case would measure nothing.
t28h="$TMP/t28h"; adopt_kit "$t28h" edge system installed-version $EDGE_BINS
h28h="$t28h/home"; ch28h="$h28h/sys-etc/burrowee/edge"; cd28h="$h28h/sys-var/burrowee/edge"
mkdir -p "$ch28h" "$cd28h" "$h28h/stubs"
# The operator's account. The name is one no real host has: home_of_user asks
# getent/dscl BEFORE the seeded parents, so a name that happens to exist on the
# machine running this suite would resolve to a REAL home directory.
seed_real_tree "$h28h/homes/burrowee-fixture-op/.burrowee/edge"
seed_stub_tree "$h28h/.burrowee/edge"          # $HOME's tree — the wrong answer
seed_ours "$h28h/usr-local-bin" $EDGE_BINS
make_cli_stub "$h28h/usr-local-bin" edge
make_supervisor_stub "$h28h/stubs" kills
ADOPT_COMP_DATA="$cd28h" ADOPT_SUDO_USER=burrowee-fixture-op \
ADOPT_HOME_PARENTS="$h28h/homes" \
run_adopt_ladder "$t28h" "$h28h" "$ch28h" "$h28h/usr-local-bin" "$h28h/stubs" --installed-version 0.0.0
assert_eq "$RC" 2 "\$SUDO_USER's tree holds the identity and must be adopted"
assert_contains "$OUT" "adopted $h28h/homes/burrowee-fixture-op/.burrowee/edge" "the run must name \$SUDO_USER's tree, not \$HOME's"
assert_eq "$(cat "$ch28h/identity/relay_ed.key")" "PRIVATE-KEY-BYTES-the-operators-tree" "under sudo \$HOME is root's — the identity must come from \$SUDO_USER's tree"

# 28g. ROOT'S TREE IS NOT CONSULTED FOR BLINDNESS EITHER. Root's is unreadable
#      and the running user's is readable-and-empty: the answer is "nothing to
#      adopt", because the only candidate answered provably. A rung that still
#      counted root's tree would report "still needed" forever on such a host.
if [ "$(id -u)" = 0 ]; then
    fail "case 28g must not run as root: chmod 000 does not blind uid 0."
else
t28g="$TMP/t28g"; adopt_kit "$t28g" edge system installed-version $EDGE_BINS
h28g="$t28g/home"; ch28g="$h28g/sys-etc/burrowee/edge"; cd28g="$h28g/sys-var/burrowee/edge"
mkdir -p "$ch28g" "$cd28g" "$h28g/stubs" "$h28g/.burrowee/edge"
seed_tree "$h28g/root-home/.burrowee/edge" root.example.org
chmod 000 "$h28g/root-home/.burrowee/edge/identity"
if [ -r "$h28g/root-home/.burrowee/edge/identity/relay_ed.key" ]; then
    fail "case 28g fixture is readable — the blindness assertion would prove nothing"
fi
OUT="$(HOME="$h28g" COMP_HOME="$ch28g" COMP_DATA="$cd28g" ROOT_HOME="$h28g/root-home" \
    BIN_DIR="$h28g/usr-local-bin" BURROWEE_LEGACY_HOME_PARENTS="$h28g/nowhere" SUDO=/nonexistent-sudo \
    sh "$t28g/migrations/adopt_user_tree.sh" --applies 2>&1)"; RC=$?
assert_eq "$RC" 1 "an unreadable ROOT tree is not evidence of anything — it is not a candidate"
chmod 700 "$h28g/root-home/.burrowee/edge/identity"
fi

# ---------------------------------------------------------------------------
# 29. admin-kr's EXACT SHAPE UNDER THE SPLIT: the running user's tree holding
#     the real state, root's home holding the stub copy the operator was given
#     during the outage, the machine-owned roots empty, the anchor already
#     reading 0.2.0 — driven through upgrade.sh, which is run.sh
#     --assume-below 0.2.0 --rerun-recorded.
#
#     The daemon's running.json is in the DATA root, which is what makes this
#     also the assertion that the rung looks there: a version that only probed
#     $COMP_HOME would miss a live daemon and copy underneath it.
# ---------------------------------------------------------------------------
t29="$TMP/t29"; adopt_kit "$t29" edge system installed-version $EDGE_BINS
h29="$t29/home"; ch29="$h29/sys-etc/burrowee/edge"; cd29="$h29/sys-var/burrowee/edge"
mkdir -p "$ch29" "$cd29" "$h29/stubs"
seed_real_tree "$h29/.burrowee/edge"
seed_stub_tree "$h29/root-home/.burrowee/edge"
seed_ours "$h29/usr-local-bin" $EDGE_BINS
make_cli_stub "$h29/usr-local-bin" edge
make_supervisor_stub "$h29/stubs" kills
echo "0.2.0.2026.08.19.78a2c91a" > "$ch29/installed-version"
D29_PID="$(start_fake_daemon "$h29/daemon" burrowee-edge)"
printf '{"pid": %s, "version": "0.2.0"}\n' "$D29_PID" > "$cd29/running.json"
STOP_PIDFILE="$h29/daemon.pid"; echo "$D29_PID" > "$STOP_PIDFILE"; export STOP_PIDFILE
# BEFORE: the machine roots hold nothing.
assert_gone "$ch29/identity/relay_ed.key" "BEFORE: the config root holds no identity"
assert_gone "$ch29/config" "BEFORE: the config root holds no config"
UPGRADE_OUT="$(
    HOME="$h29" COMP_HOME="$ch29" COMP_DATA="$cd29" BIN_DIR="$h29/usr-local-bin" \
    SYS_CONFIG_ROOT="$h29/sys-etc/burrowee" SYS_DATA_ROOT="$h29/sys-var/burrowee" \
    ROOT_HOME="$h29/root-home" \
    LAUNCHD_DIR="$h29/no-launchd" SYSTEMD_DIR="$h29/no-systemd" \
    BURROWEE_LEGACY_HOME_PARENTS="$h29/nowhere" SUDO="$h29/stubs/sudo" \
    SYSTEMCTL="$h29/stubs/supervisor" LAUNCHCTL="$h29/stubs/supervisor" \
    CLI_STUB_LOG="$h29/stubs/cli.log" BURROWEE_MIGRATE_STOP_TIMEOUT=5 \
    sh "$t29/migrations/upgrade.sh" 0.2.0 2>&1
)"; UPGRADE_RC=$?
assert_eq "$UPGRADE_RC" 2 "upgrade.sh must force the adoption on a 0.2.0-anchored host"
assert_contains "$UPGRADE_OUT" "adopted $h29/.burrowee/edge" "the rung must name the running user's tree as the source it took"
# AFTER: the machine CONFIG root holds the state, byte for byte.
assert_present "$ch29/identity/relay_ed.key" "AFTER: the config root must HOLD the identity"
R29="$(retired_tree "$h29/.burrowee/edge")"
assert_eq "$(cat "$ch29/config")" "$(cat "$R29/config")" "AFTER: the adopted config must be the running user's config"
# tls_listen is the line root's stub does not have, and its absence is what made
# the daemon try to bind privileged :443 unprivileged. Asserted by name because
# a plain equality would also pass for a one-line file if the fixtures drifted.
assert_contains "$(cat "$ch29/config")" "tls_listen=127.0.0.1:9443" "AFTER: the adopted config must carry tls_listen — root's stub does not, and its absence crash-looped the daemon"
# AFTER: THE SOURCE IS RETIRED, NOT DELETED. The cli renames the tree it verified
# to <tree>.bak.<stamp> (retired_tree resolves the stamp and checks there is
# exactly one); every byte is still there, and recovery is one `mv` back.
assert_gone "$h29/.burrowee/edge" "AFTER: a verified adoption must not leave the source at its live name — that is the tree \`doctor\` reads as a second edge"
assert_present "$R29/identity/relay_ed.key" "AFTER: the retired tree keeps every byte — a rename, never a delete"
assert_eq "$(cat "$R29/config")" "$(cat "$ch29/config")" "AFTER: the retired tree still holds the config the destination adopted"
assert_present "$h29/root-home/.burrowee/edge/identity/relay_ed.key" "AFTER: and root's tree is untouched"
assert_present "$ch29/migration-receipts/adopt_user_tree.sh@0.2.0.done" "the runner must record the rung in the CONFIG root"
# THE RUNG SAW THE DAEMON THROUGH THE DATA ROOT and stopped it before copying.
assert_contains "$(cat "$h29/stubs/supervisor.log")" "stop burrowee-edge" "running.json lives in the DATA root — the rung must probe there and stop the daemon"
assert_contains "$UPGRADE_OUT" "burrowee-edge is STOPPED" "the runner's last line must say the daemon is down"
STOP_PIDFILE=""; export STOP_PIDFILE
kill "$D29_PID" 2>/dev/null || true

# 29b. THE cli COMPONENT, RE-ASSERTED AGAINST THE NEW SCHEME. `system` is
#      per-component and cli sets none, so it keeps the `user` default and one
#      tree. Asserted here rather than inferred: the runner is shared, and the
#      whole cost of adding a scheme is that it must change nothing for the
#      component that does not use it.
t29b="$TMP/t29b"; kit "$t29b" cli user .installed-version $CLI_BINS
assert_lacks "$(cat "$t29b/migrations/component.conf")" "COMP_HOME_SCHEME=system" "cli must not carry the system scheme"
assert_contains "$(cat "$t29b/migrations/component.conf")" "COMP_HOME_SCHEME=user" "cli stays on the user scheme"
h29b="$t29b/home"; ch29b="$h29b/.burrowee/cli"; mkdir -p "$ch29b" "$h29b/stubs"
seed_ours "$h29b/.local/bin" $CLI_BINS
seed_twins "$h29b/usr-local-bin" $CLI_BINS
make_supervisor_stub "$h29b/stubs" kills
# COMP_DATA is deliberately named as something ELSE. A `user`-scheme component
# must resolve one tree regardless of what is passed, or a stray variable in a
# caller's environment would split a component that never made the split.
OUT="$(
    HOME="$h29b" COMP_HOME="$ch29b" COMP_DATA="$h29b/should-never-be-used" \
    BIN_DIR="$h29b/usr-local-bin" \
    LAUNCHD_DIR="$h29b/no-launchd" SYSTEMD_DIR="$h29b/no-systemd" \
    BURROWEE_LEGACY_HOME_PARENTS="$h29b/nowhere" SUDO=/nonexistent-sudo \
    sh "$t29b/migrations/run.sh" 2>&1
)"; RC=$?
assert_eq "$RC" 2 "cli's ladder still runs its sweep exactly as before"
assert_gone "$h29b/should-never-be-used" "a user-scheme component must ignore \$COMP_DATA entirely"
assert_lacks "$OUT" "should-never-be-used" "and it must not even NAME it — the runner reports the trees it resolved, and a user-scheme component has one"
assert_contains "$OUT" "component tree $ch29b" "the runner must name the one tree it is about"
assert_present "$ch29b/migration-receipts/stale_user_bins.sh@0.2.0.done" "and its receipt still lands in its one tree"

# 29c. A system-SCHEME KIT NAMED WITH HALF A PAIR IS REFUSED. Pairing a named
#      tree with a defaulted one is how a run reads config from one install and
#      writes state into another — the defect the split ends rather than moves.
t29c="$TMP/t29c"; adopt_kit "$t29c" edge system installed-version $EDGE_BINS
h29c="$t29c/home"; ch29c="$h29c/sys-etc/burrowee/edge"; mkdir -p "$ch29c"
OUT="$(HOME="$h29c" COMP_HOME="$ch29c" BIN_DIR="$h29c/usr-local-bin" \
    BURROWEE_LEGACY_HOME_PARENTS="$h29c/nowhere" SUDO=/nonexistent-sudo \
    sh "$t29c/migrations/run.sh" 2>&1)"; RC=$?
assert_eq "$RC" 1 "a system-scheme run given \$COMP_HOME without \$COMP_DATA must refuse"
assert_contains "$OUT" "Refusing rather than pairing the tree you named" "the refusal must say why"

# 29d. AN ABSENT MACHINE ROOT IS EVALUATED, NOT SKIPPED. For a `user`/`root`
#      component an absent tree means "the ladder is aimed at the wrong
#      account"; for a `system` one it is the state to migrate FROM, and the
#      rung that creates it is on this ladder. Skipping there would refuse to
#      run the adoption on exactly the hosts that need it.
t29d="$TMP/t29d"; adopt_kit "$t29d" edge system installed-version $EDGE_BINS
h29d="$t29d/home"; ch29d="$h29d/sys-etc/burrowee/edge"; cd29d="$h29d/sys-var/burrowee/edge"
mkdir -p "$h29d/stubs"
seed_tree "$h29d/.burrowee/edge" absent.example.org
seed_ours "$h29d/usr-local-bin" $EDGE_BINS
make_cli_stub "$h29d/usr-local-bin" edge
make_supervisor_stub "$h29d/stubs" kills
if [ -d "$ch29d" ]; then fail "case 29d fixture: the config root must NOT exist"; fi
ADOPT_COMP_DATA="$cd29d" \
run_adopt_ladder "$t29d" "$h29d" "$ch29d" "$h29d/usr-local-bin" "$h29d/stubs"
assert_eq "$RC" 2 "an absent machine root must be migrated, not skipped"
assert_contains "$OUT" "has not converged on the" "the runner must say why it evaluated anyway"
assert_present "$ch29d/identity/relay_ed.key" "and the adoption must have created and filled the config root"

# ---------------------------------------------------------------------------
# 30. THE FORCED ADOPTION. A tree adopted from the WRONG source, which the
#     never-overwrite copy can never repair, and which the operator repairs by
#     re-running the migration — no manual copying, no follow-up commands.
#
#     This is admin-kr AFTER the withdrawn aa21f55c: the destination is
#     populated and wrong in two ways at once. present-but-different
#     (identity/relay_ed.key, config — what a root daemon minted for itself
#     against an empty tree) and absent (everything root's home never had). And
#     it holds install records of its own — installed-version,
#     migration-receipts/, migrations/ — which describe THIS install and must
#     survive untouched.
# ---------------------------------------------------------------------------
t30="$TMP/t30"; adopt_kit "$t30" edge system installed-version $EDGE_BINS
h30="$t30/home"; ch30="$h30/sys-etc/burrowee/edge"; cd30="$h30/sys-var/burrowee/edge"
mkdir -p "$ch30/identity" "$cd30" "$h30/stubs"
seed_per_user_tree "$h30/.burrowee/edge"
# present-but-different. The two values MUST differ or an overwrite is
# unobservable and the case passes either way.
printf 'MINTED-BY-THE-ROOT-DAEMON\n' > "$ch30/identity/relay_ed.key"
printf 'lan_listen=127.0.0.1:9448\n' > "$ch30/config"
if [ "$(cat "$ch30/identity/relay_ed.key")" = "$(cat "$h30/.burrowee/edge/identity/relay_ed.key")" ]; then
    fail "case 30 fixture: the two identities are equal, so a replacement is unobservable"
fi
# the destination's OWN install records.
echo "0.2.0.2026.08.19.72743ca2" > "$ch30/installed-version"
mkdir -p "$ch30/migration-receipts"
# A receipt for a rung NOT on this ladder: the runner legitimately writes its
# own receipts for the rungs it runs, so asserting against one of those would be
# asserting that the runner does not work.
echo "earned by $ch30" > "$ch30/migration-receipts/some_earlier_rung.sh.done"
seed_ours "$h30/usr-local-bin" $EDGE_BINS
make_cli_stub "$h30/usr-local-bin" edge
make_supervisor_stub "$h30/stubs" kills

# 30a. THE PLAIN LADDER STILL CANNOT REPAIR IT, and that is the whole premise.
#      The anchor reads 0.2.0 and the destination holds an identity, so the
#      numeric gate and --applies both decline.
ADOPT_COMP_DATA="$cd30" \
run_adopt_ladder "$t30" "$h30" "$ch30" "$h30/usr-local-bin" "$h30/stubs"
assert_eq "$RC" 0 "the plain ladder must decline on a wrongly-adopted host — this is the state the operator is stuck in"
assert_eq "$(cat "$ch30/identity/relay_ed.key")" "MINTED-BY-THE-ROOT-DAEMON" "the plain ladder must not have replaced anything"

# 30b. FORCED — the operator re-runs the migration, and the host is repaired.
UPGRADE30="$(
    HOME="$h30" COMP_HOME="$ch30" COMP_DATA="$cd30" BIN_DIR="$h30/usr-local-bin" \
    SYS_CONFIG_ROOT="$h30/sys-etc/burrowee" SYS_DATA_ROOT="$h30/sys-var/burrowee" \
    ROOT_HOME="$h30/root-home" \
    LAUNCHD_DIR="$h30/no-launchd" SYSTEMD_DIR="$h30/no-systemd" \
    BURROWEE_LEGACY_HOME_PARENTS="$h30/nowhere" SUDO="$h30/stubs/sudo" \
    SYSTEMCTL="$h30/stubs/supervisor" LAUNCHCTL="$h30/stubs/supervisor" \
    CLI_STUB_LOG="$h30/stubs/cli.log" BURROWEE_MIGRATE_STOP_TIMEOUT=2 \
    sh "$t30/migrations/upgrade.sh" 0.2.0 2>&1
)"; UPGRADE30_RC=$?
assert_eq "$UPGRADE30_RC" 2 "upgrade.sh must run the adoption on a wrongly-adopted host"
# THE FLAG REACHED THE CLI. Without this the rung could announce a forced run and
# invoke the ordinary, never-overwriting copy.
assert_contains "$(cat "$h30/stubs/cli.log")" "--force" "the rung must pass --force to the cli on a forced run"
# AND THE DESTINATION ACTUALLY CHANGED.
assert_eq "$(cat "$ch30/identity/relay_ed.key")" "PRIVATE-KEY-BYTES" "the destination must now hold the RUNNING USER's identity"
R30="$(retired_tree "$h30/.burrowee/edge")"
assert_eq "$(cat "$ch30/config")" "$(cat "$R30/config")" "the destination config must now be the running user's"
# THE DESTINATION'S OWN INSTALL RECORDS SURVIVE. Carrying installed-version would
# tell this ladder it had run rungs it has not; migration-receipts/ is worse.
assert_eq "$(cat "$ch30/installed-version")" "0.2.0.2026.08.19.72743ca2" "installed-version belongs to THIS install and must not be carried"
assert_eq "$(cat "$ch30/migration-receipts/some_earlier_rung.sh.done")" "earned by $ch30" "migration-receipts/ belongs to THIS tree and must not be carried"
# COPY, NEVER MOVE — still true when forcing, and the retirement is too: a forced
# run is exactly the run whose source an operator may have to restore.
assert_present "$R30/identity/relay_ed.key" "the per-user tree must survive a forced run too"
# AND THE OPERATOR IS TOLD, BEFORE AND AFTER, THAT AN IDENTITY WAS REPLACED.
assert_contains "$UPGRADE30" "FORCED RUN" "a forced run must announce itself before the stop"
assert_contains "$UPGRADE30" "REPLACED it with" "a run that swapped the node identity must say so"
assert_contains "$UPGRADE30" "unknown-relay" "the notice must name what a wrong source looks like afterwards"

# 30c. THE UNFORCED PATH IS UNCHANGED. Same populated-and-wrong destination, and
#      never-overwrite still holds. Without this the change is unguarded:
#      "forced overwrites" is also satisfied by a rung that always does.
#
#      THE ANCHOR IS 0.1.115, NOT ABSENT, and that is the whole design of this
#      case. With no recorded version the --applies probe decides, sees an
#      identity at the destination, and declines — so the rung never runs, the
#      cli is never invoked, and both assertions below pass without measuring
#      anything. An old anchor opens the numeric gate instead, the probe loses
#      its veto, and the rung actually executes against a populated destination:
#      the only arrangement in which "it did not overwrite" is a finding.
t30c="$TMP/t30c"; adopt_kit "$t30c" edge system installed-version $EDGE_BINS
h30c="$t30c/home"; ch30c="$h30c/sys-etc/burrowee/edge"; cd30c="$h30c/sys-var/burrowee/edge"
mkdir -p "$ch30c/identity" "$cd30c" "$h30c/stubs"
seed_per_user_tree "$h30c/.burrowee/edge"
printf 'MINTED-BY-THE-ROOT-DAEMON\n' > "$ch30c/identity/relay_ed.key"
echo "0.1.115" > "$ch30c/installed-version"
seed_ours "$h30c/usr-local-bin" $EDGE_BINS
make_cli_stub "$h30c/usr-local-bin" edge
make_supervisor_stub "$h30c/stubs" kills
ADOPT_COMP_DATA="$cd30c" \
run_adopt_ladder "$t30c" "$h30c" "$ch30c" "$h30c/usr-local-bin" "$h30c/stubs"
assert_eq "$RC" 2 "fixture premise: the unforced rung must actually RUN, or the assertions below measure nothing"
assert_present "$h30c/stubs/cli.log" "fixture premise: the cli must have been invoked"
assert_eq "$(cat "$ch30c/identity/relay_ed.key")" "MINTED-BY-THE-ROOT-DAEMON" "the UNFORCED ladder must never overwrite a destination identity"
assert_lacks "$(cat "$h30c/stubs/cli.log")" "--force" "the unforced ladder must not pass --force"
assert_lacks "$OUT" "FORCED RUN" "an unforced run must not announce itself as forced"

# 30d. A FORCED RUN WITH NOTHING TO ADOPT FROM STILL DECLINES. Forcing widens
#      what may be overwritten, never what may be read: with no source tree
#      there is nothing to copy, and answering "applies" would leave a receipt
#      for work that could not happen.
t30d="$TMP/t30d"; adopt_kit "$t30d" edge system installed-version $EDGE_BINS
h30d="$t30d/home"; ch30d="$h30d/sys-etc/burrowee/edge"; cd30d="$h30d/sys-var/burrowee/edge"
mkdir -p "$ch30d/identity" "$cd30d" "$h30d/stubs" "$h30d/.burrowee/edge"
printf 'MINTED-BY-THE-ROOT-DAEMON\n' > "$ch30d/identity/relay_ed.key"
seed_ours "$h30d/usr-local-bin" $EDGE_BINS
make_cli_stub "$h30d/usr-local-bin" edge
make_supervisor_stub "$h30d/stubs" kills
ADOPT_COMP_DATA="$cd30d" \
run_adopt_ladder "$t30d" "$h30d" "$ch30d" "$h30d/usr-local-bin" "$h30d/stubs" --rerun-recorded
assert_eq "$(cat "$ch30d/identity/relay_ed.key")" "MINTED-BY-THE-ROOT-DAEMON" "a forced run with an unenrolled source must change nothing"
assert_contains "$OUT" "adopt_user_tree.sh skipped" "and it must say it evaluated and declined"

# 30e. FORCED WITH NO NAMED VERSION — where the --applies branch is the ONLY
#      thing selecting the rung.
#
#      30b goes through upgrade.sh, which names --assume-below <floor>, and a
#      named floor makes --applies advisory (run.sh's header: the probe gets no
#      veto). So 30b cannot tell whether the forced --applies branch works at
#      all. Here there is no anchor and no named version, so the probe DECIDES:
#      without the forced branch it sees an identity at the destination, answers
#      "already carried over", and the rung is skipped on exactly the host the
#      flag exists for.
t30e="$TMP/t30e"; adopt_kit "$t30e" edge system installed-version $EDGE_BINS
h30e="$t30e/home"; ch30e="$h30e/sys-etc/burrowee/edge"; cd30e="$h30e/sys-var/burrowee/edge"
mkdir -p "$ch30e/identity" "$cd30e" "$h30e/stubs"
seed_per_user_tree "$h30e/.burrowee/edge"
printf 'MINTED-BY-THE-ROOT-DAEMON\n' > "$ch30e/identity/relay_ed.key"
seed_ours "$h30e/usr-local-bin" $EDGE_BINS
make_cli_stub "$h30e/usr-local-bin" edge
make_supervisor_stub "$h30e/stubs" kills
ADOPT_COMP_DATA="$cd30e" \
run_adopt_ladder "$t30e" "$h30e" "$ch30e" "$h30e/usr-local-bin" "$h30e/stubs" --rerun-recorded
assert_eq "$RC" 2 "a forced run must be SELECTED on a populated destination even with no named version"
assert_eq "$(cat "$ch30e/identity/relay_ed.key")" "PRIVATE-KEY-BYTES" "and it must replace the destination identity"

# ---------------------------------------------------------------------------
# 31. THE FLOOR SELECTS BY TARGET. upgrade.sh's argument is an inclusive floor,
#     and on a ladder with rungs on BOTH sides of it the floor is what decides:
#     every rung targeting the floor or newer is selected and re-run, every
#     strictly older rung is treated as genuinely done — an operator forcing
#     0.2.0's work on a host whose 0.1.x rungs really did run must not have
#     that older work reopened as a side effect. The single-rung sections above
#     cannot see this at all, so the ladder here carries two targets and the
#     rungs drop MARKERS: which rungs RAN is the whole claim, and output alone
#     cannot prove a rung did not.
# ---------------------------------------------------------------------------
# stub_rung <kit> <name> — a minimal rung honoring the rung contract: --applies
# exits 0 (always still needed — these sections test SELECTION, not evidence), a
# bare invocation performs (APPENDS a line to <name>.ran in $COMP_HOME, so the
# marker also counts HOW MANY times the file ran — case 34b's whole claim) and
# exits 0, and anything else exits 64.
stub_rung() {
    cat > "$1/migrations/$2" <<EOF
#!/bin/sh
set -eu
if [ "\$#" -gt 0 ]; then
    [ "\$1" = "--applies" ] || exit 64
    exit 0
fi
printf 'ran\n' >> "\$COMP_HOME/$2.ran"
exit 0
EOF
    chmod 0755 "$1/migrations/$2"
}

# two_rung_kit <dir> — the section-31 ladder: one rung below the 0.2.0 line and
# one on it, replacing the kit's default single-row ledger.
two_rung_kit() {
    kit "$1" edge root installed-version $EDGE_BINS
    stub_rung "$1" old_rung.sh
    stub_rung "$1" new_rung.sh
    printf '# ledger\n0.1.5 old_rung.sh\n0.2.0 new_rung.sh\n' > "$1/migrations/ledger"
}

# 31a. floor 0.2.0: ONLY the 0.2.0 rung runs; the 0.1.5 rung is genuinely done —
#      not listed, not run, its marker untouched — and the skip note counts it.
t31="$TMP/t31"; two_rung_kit "$t31"
h31="$t31/home"; ch31="$h31/root-home/.burrowee/edge"; mkdir -p "$ch31"
run_upgrade "$t31" "$h31" "$ch31" "$h31/usr-local-bin" 0.2.0
assert_eq "$RC" 2 "a floor with a rung on it must run that rung"
assert_contains "$OUT" "every rung targeting 0.2.0 or newer will be re-run" "the pre-run list must announce the floor's selection"
assert_contains "$OUT" "new_rung.sh (target 0.2.0)" "the list must name the rung at the floor"
assert_lacks "$OUT" "old_rung.sh (target 0.1.5)" "the pre-run list holds only SELECTED rungs"
assert_contains "$OUT" "(1 older rung(s) below the floor are treated as genuinely done and skipped)" "the skip note must count the rung below the floor"
assert_contains "$OUT" "old_rung.sh skipped: its target 0.1.5 is older than the floor 0.2.0" "the runner must skip the older rung as genuinely done"
assert_present "$ch31/new_rung.sh.ran" "the rung at the floor must have RUN"
assert_gone "$ch31/old_rung.sh.ran" "the rung below the floor must NOT have been touched"

# 31b. floor 0.1.0, same ladder: both targets are at or above it, so BOTH run —
#      and with nothing below the floor there is no skip note to print.
t31b="$TMP/t31b"; two_rung_kit "$t31b"
h31b="$t31b/home"; ch31b="$h31b/root-home/.burrowee/edge"; mkdir -p "$ch31b"
run_upgrade "$t31b" "$h31b" "$ch31b" "$h31b/usr-local-bin" 0.1.0
assert_eq "$RC" 2 "a floor below both targets must run the whole ladder"
assert_present "$ch31b/old_rung.sh.ran" "the 0.1.5 rung is above the 0.1.0 floor and must run"
assert_present "$ch31b/new_rung.sh.ran" "the 0.2.0 rung must run too"
assert_lacks "$OUT" "older rung(s) below the floor" "a run that skipped nothing must not claim it did"

# ---------------------------------------------------------------------------
# 32. --assume-below's COMMAND LINE — 64, never 2, and never half-honored.
#     The two version flags answer OPPOSITE questions about rungs targeting the
#     named line ('was on 0.2.0' skips them, 'assume below 0.2.0' runs them),
#     so a command naming both has no one meaning; and the floor takes the same
#     refuse-not-round rule as --installed-version (case 12).
# ---------------------------------------------------------------------------
t32="$TMP/t32"; kit "$t32" edge root installed-version $EDGE_BINS
h32="$t32/home"; ch32="$h32/root-home/.burrowee/edge"; mkdir -p "$ch32"
seed_ours "$h32/.local/bin" $EDGE_BINS
seed_twins "$h32/usr-local-bin" $EDGE_BINS
run_ladder "$t32" "$h32" "$ch32" "$h32/usr-local-bin" --assume-below 0.2.0 --installed-version 0.2.0
assert_eq "$RC" 64 "--assume-below with --installed-version has no one meaning and must be refused"
assert_contains "$OUT" "--installed-version and --assume-below were both given" "the refusal must name BOTH flags"
assert_contains "$OUT" "nothing has been touched" "the refusal must say nothing was touched"
run_ladder "$t32" "$h32" "$ch32" "$h32/usr-local-bin" --assume-below 0.2.x
assert_eq "$RC" 64 "an unparseable floor must be refused, never rounded to 0.2.0"
assert_contains "$OUT" "nothing has been touched" "a refusal must say nothing was touched"
run_ladder "$t32" "$h32" "$ch32" "$h32/usr-local-bin" --assume-below ""
assert_eq "$RC" 64 "an EMPTY --assume-below must be refused, not read as 'not given'"
assert_present "$h32/.local/bin/burrowee-edge" "no refusal above may actually have touched the tree"

# ---------------------------------------------------------------------------
# 33. STRICT vs INCLUSIVE — the load-bearing distinction between the two flags,
#     on one host. The ladder's rung targets 0.2.0, there is no anchor and no
#     receipt, so the flag alone decides: --installed-version 0.2.0 says the
#     0.2.0 work is DONE and must skip it; --assume-below 0.2.0 says it is NOT
#     and must run it. A gate that drifted exclusive would make upgrade.sh's
#     whole forcing path a silent no-op on every same-semver host — the exact
#     state section 17's operator was stuck in.
# ---------------------------------------------------------------------------
t33="$TMP/t33"; kit "$t33" edge root installed-version $EDGE_BINS
h33="$t33/home"; ch33="$h33/root-home/.burrowee/edge"; mkdir -p "$ch33"
seed_ours "$h33/.local/bin" $EDGE_BINS
seed_twins "$h33/usr-local-bin" $EDGE_BINS
run_ladder "$t33" "$h33" "$ch33" "$h33/usr-local-bin" --installed-version 0.2.0
assert_eq "$RC" 0 "--installed-version 0.2.0 is STRICT: a rung targeting exactly 0.2.0 is done"
assert_contains "$OUT" "stale_user_bins.sh skipped: installed 0.2.0 is not older than 0.2.0" "the strict gate must skip the equal-target rung and say why"
assert_present "$h33/.local/bin/burrowee-edge" "the strictly-gated run may touch nothing"
run_ladder "$t33" "$h33" "$ch33" "$h33/usr-local-bin" --assume-below 0.2.0
assert_eq "$RC" 2 "--assume-below 0.2.0 is INCLUSIVE: the same rung on the same host must RUN"
assert_contains "$OUT" "stale_user_bins.sh applies: its target 0.2.0 is at or above the floor 0.2.0" "the floor gate must select the equal-target rung and say why"
assert_gone "$h33/.local/bin/burrowee-edge" "the floor-gated run must have swept"

# ---------------------------------------------------------------------------
# 34. THE RECEIPT IS PER ITEM — per ledger ROW, `<script>@<target>.done` — not
#     per script file. One FILE may legitimately appear on several rows
#     (re-listed at a newer target when a line gains a step), and a receipt
#     keyed by the file alone would let the run that satisfied the 0.2.0 row
#     silently satisfy a later 0.3.0 row too: the receipt check runs BEFORE the
#     version gate, so the gate would never even see the new item. A legacy
#     target-less receipt (`<script>.done`, written before receipts carried the
#     target) is honored ONLY while the ledger names that script exactly once —
#     with one row there is exactly one item the old receipt could have
#     witnessed.
# ---------------------------------------------------------------------------
# 34a. THE LEGACY FALLBACK: a target-less receipt naming this tree still skips
#      the rung while the ledger's single row keeps it unambiguous — the hosts
#      already in the field must not re-run a receipted rung just because the
#      receipt scheme moved under them.
t34="$TMP/t34"; kit "$t34" edge root installed-version $EDGE_BINS
h34="$t34/home"; ch34="$h34/root-home/.burrowee/edge"; mkdir -p "$ch34/migration-receipts"
seed_ours "$h34/.local/bin" $EDGE_BINS
seed_twins "$h34/usr-local-bin" $EDGE_BINS
printf 'stale_user_bins.sh\ncomp_home=%s\n' "$ch34" > "$ch34/migration-receipts/stale_user_bins.sh.done"
run_ladder "$t34" "$h34" "$ch34" "$h34/usr-local-bin"
assert_eq "$RC" 0 "a legacy receipt naming this tree must still skip a once-listed script"
assert_contains "$OUT" "stale_user_bins.sh skipped: its receipt records it completed here" "the legacy receipt must be honored with the same skip wording"
assert_present "$h34/.local/bin/burrowee-edge" "the legacy-receipted rung must not have run"

# 34b. THE MISS-PROOF CASE: the same script re-listed at a newer target. The
#      host recorded 0.2.5 and holds the legacy receipt its 0.2.0 run earned;
#      the kit's ledger now lists the SAME file again at 0.3.0. The 0.2.0 item
#      is the version gate's to skip; the 0.3.0 item must RUN — a legacy
#      receipt that cannot say which item it witnessed settles neither — and
#      the run must leave a per-item receipt naming the target, so a third
#      listing can never be answered for by this one.
t34b="$TMP/t34b"; kit "$t34b" edge root installed-version $EDGE_BINS
stub_rung "$t34b" twice_listed.sh
printf '# ledger\n0.2.0 twice_listed.sh\n0.3.0 twice_listed.sh\n' > "$t34b/migrations/ledger"
h34b="$t34b/home"; ch34b="$h34b/root-home/.burrowee/edge"; mkdir -p "$ch34b/migration-receipts"
echo "0.2.5" > "$ch34b/installed-version"
printf 'twice_listed.sh\ncomp_home=%s\n' "$ch34b" > "$ch34b/migration-receipts/twice_listed.sh.done"
run_ladder "$t34b" "$h34b" "$ch34b" "$h34b/usr-local-bin"
assert_eq "$RC" 2 "the re-listed 0.3.0 item must run — a target-less receipt settles nothing once a second row names the script"
assert_contains "$OUT" "twice_listed.sh skipped: installed 0.2.5 is not older than 0.2.0" "the 0.2.0 item is the version gate's to skip, not the legacy receipt's"
assert_contains "$OUT" "running twice_listed.sh (target 0.3.0)" "the run phase must name the ITEM it is running"
assert_eq "$(wc -l < "$ch34b/twice_listed.sh.ran" | tr -d ' ')" 1 "the file must run exactly once — the 0.3.0 item only"
assert_present "$ch34b/migration-receipts/twice_listed.sh@0.3.0.done" "the run must leave a PER-ITEM receipt naming the target"
assert_contains "$(cat "$ch34b/migration-receipts/twice_listed.sh@0.3.0.done")" "target=0.3.0" "and its body must record the target it was earned for"
run_ladder "$t34b" "$h34b" "$ch34b" "$h34b/usr-local-bin"
assert_eq "$RC" 0 "a second run must find the per-item receipt and apply nothing"
assert_contains "$OUT" "nothing applied" "and say it evaluated and declined"
assert_eq "$(wc -l < "$ch34b/twice_listed.sh.ran" | tr -d ' ')" 1 "and must not have run the file again"

# ---------------------------------------------------------------------------
# 35. repoint_lan_cert.sh — the 0.2.11 rung that repairs what the 0.2.0 adoption
# left behind: a lan_cert still naming the tree the adoption retired.
#
# EVERY CASE DRIVES THE REAL RUNG, not the ladder: the runner's gate, receipts
# and ordering are cases 1-34's subject, and re-proving them here would only
# prove the fixture. What is under test is the rung's own decision.
#
# THE SUDO STUB EXECS. Every read and the write go through elevate, because the
# tree this rung repairs is root-owned 0700 — a rung that read as the invoking
# user would see "no config" on exactly the hosts it exists for. The stub also
# RECORDS, so a case can prove the elevation happened rather than assuming it.
lc_fixture() {
    # lc_fixture <dir> <lan_cert-value> — a component tree with a config in the
    # shape a pre-collapse enrolled host actually held.
    _lcf="$1"
    mkdir -p "$_lcf/home" "$_lcf/stubs"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/stubs/sudo.log"\nexec "$@"\n' "$_lcf" > "$_lcf/stubs/sudo"
    chmod 755 "$_lcf/stubs/sudo"
    printf '# edge config\ntls_listen=:8448\nserve_mode=lan\nlan_cert=%s\nlan_listen=127.0.0.1:9448\n' "$2" > "$_lcf/home/config"
}
lc_pair() { mkdir -p "$1"; printf 'cert\n' > "$1/cert.pem"; printf 'key\n' > "$1/key.pem"; }
run_repoint() {
    # run_repoint <dir> [args…]
    _rr="$1"; shift
    OUT="$(
        COMP=edge COMP_HOME="$_rr/home" COMP_DATA="$_rr/home" \
        BIN_DIR="$_rr/bin" SUDO="$_rr/stubs/sudo" \
        sh "$SHARED/repoint_lan_cert.sh" "$@" 2>&1
    )"
    RC=$?
}
lc_value() { sed -n 's/^lan_cert=//p' "$1/home/config"; }

# 35a. THE LIVE DEFECT. The value names a retired tree; the carried pair is at
# the canonical name. The probe must select it and the run must repoint.
t35a="$TMP/t35a"; lc_fixture "$t35a" "$TMP/t35a-retired/.burrowee/edge/lan-cert"
lc_pair "$t35a/home/lan-cert"
run_repoint "$t35a" --applies
assert_eq "$RC" 0 "a lan_cert naming the retired tree, with a pair to repoint to, must select the rung"
run_repoint "$t35a"
assert_eq "$RC" 0 "the repoint must succeed"
assert_eq "$(lc_value "$t35a")" "$t35a/home/lan-cert" "the config must name the carried pair"
assert_contains "$OUT" "the fingerprint peers pinned is unchanged" "the run must say the identity peers trust did not move"
assert_contains "$(cat "$t35a/home/config")" "lan_listen=127.0.0.1:9448" "every other config line must survive the rewrite"
assert_contains "$(cat "$t35a/home/config")" "# edge config" "including the comments"
assert_contains "$(cat "$t35a/stubs/sudo.log")" "cat" "the reads must go through elevate — the real tree is root-owned 0700"

# 35b. IDEMPOTENT. A second run finds the value already right and declines.
run_repoint "$t35a" --applies
assert_eq "$RC" 1 "a repointed host must no longer select the rung"
run_repoint "$t35a"
assert_eq "$RC" 0 "and a forced re-run must be a clean no-op"
assert_eq "$(lc_value "$t35a")" "$t35a/home/lan-cert" "which must not have changed the value again"

# 35c. IT NEVER MINTS. Broken value, NO pair at the canonical name: the rung must
# do nothing, exit 0, and say why — a new pair would change the fingerprint every
# peer has pinned, which is not a repair.
t35c="$TMP/t35c"; lc_fixture "$t35c" "$TMP/t35c-retired/lan-cert"
run_repoint "$t35c" --applies
assert_eq "$RC" 1 "with no pair to repoint to there is nothing this rung can do"
run_repoint "$t35c"
assert_eq "$RC" 0 "and it must not fail the ladder over a state only an operator can resolve"
assert_eq "$(lc_value "$t35c")" "$TMP/t35c-retired/lan-cert" "the broken value must be left exactly as it was"
assert_contains "$OUT" "NOT repairing" "the unrepairable state must be named, not inferred from silence"
assert_contains "$OUT" "re-pin" "and the cost of minting must be stated"

# 35d. INERT ON A WORKING RELOCATED VALUE. lan_cert may legitimately name another
# directory INSIDE the component dir; a rung that repointed it would move a host
# off the cert its peers pinned for no reason at all.
t35d="$TMP/t35d"; lc_fixture "$t35d" "$TMP/t35d/home/pinned"
lc_pair "$t35d/home/pinned"; lc_pair "$t35d/home/lan-cert"
run_repoint "$t35d" --applies
assert_eq "$RC" 1 "a relocated lan_cert whose cert.pem is readable is not broken"
run_repoint "$t35d"
assert_eq "$(lc_value "$t35d")" "$TMP/t35d/home/pinned" "and must be left pointing where the operator put it"

# 35e. UNSET IS NOT BROKEN. No lan_cert means the daemon pins no LAN cert and the
# startup guard never fires; selecting the rung here would be a permanent
# false positive on every frontier edge that never had one.
t35e="$TMP/t35e"; lc_fixture "$t35e" "unused"
printf '# edge config\nserve_mode=frontier\n' > "$t35e/home/config"
lc_pair "$t35e/home/lan-cert"
run_repoint "$t35e" --applies
assert_eq "$RC" 1 "an unset lan_cert must not select the rung"

# 35f. A VALUE HOLDING awk/sed METACHARACTERS. `&` is the sed replacement's
# whole-match reference, so a rung that spliced the path into a sed expression
# would corrupt the config here rather than repoint it.
t35f="$TMP/t35f-a&b"; lc_fixture "$t35f" "$TMP/t35f-retired/lan-cert"
lc_pair "$t35f/home/lan-cert"
run_repoint "$t35f"
assert_eq "$RC" 0 "a component dir holding a metacharacter must still repoint"
assert_eq "$(lc_value "$t35f")" "$t35f/home/lan-cert" "and the value must be the literal path, not a sed expansion of it"

# 35g. BAD ARGUMENT. Same contract as its siblings in this directory: a typo can
# never wear a state the runner reads as a decision.
run_repoint "$t35a" --bogus
assert_eq "$RC" 2 "an unknown argument must exit 2, like the other shared rungs"
assert_contains "$OUT" "unknown argument" "and say so"

# ---------------------------------------------------------------------------
# 36. THE 0.3 ROOTS. A `system`-scheme component's two trees hang off ONE
#     machine-owned parent since 0.3 — /usr/local/burrowee/{etc,var}/<comp> —
#     and the 0.2 pair (/usr/local/{etc,var}/burrowee/<comp>) survives only as
#     the LEGACY seam the transitional anchor read and the 0.2→0.3 rungs
#     consume. These are real, fixed system paths, so they are pinned as
#     SOURCE TEXT — exactly as the Go harnesses pin the installers'
#     destinations — and never resolved by running the runner with nothing
#     exported, which would aim it at the real host.
#
#     Both files carry the pair: run.sh resolves it for every ladder run, and
#     adopt_user_tree.sh re-resolves it for a direct invocation. A default
#     that moved in one and not the other is a run that reads config out of
#     one install and writes state into another.
# ---------------------------------------------------------------------------
for _f36 in run.sh adopt_user_tree.sh; do
    assert_contains "$(cat "$SHARED/$_f36")" 'SYS_CONFIG_ROOT="${SYS_CONFIG_ROOT:-/usr/local/burrowee/etc}"' "$_f36 must default the config root to the 0.3 tree"
    assert_contains "$(cat "$SHARED/$_f36")" 'SYS_DATA_ROOT="${SYS_DATA_ROOT:-/usr/local/burrowee/var}"' "$_f36 must default the data root to the 0.3 tree"
    assert_lacks "$(cat "$SHARED/$_f36")" 'SYS_CONFIG_ROOT="${SYS_CONFIG_ROOT:-/usr/local/etc/burrowee}"' "$_f36 must not default the config root to the 0.2 tree"
    assert_lacks "$(cat "$SHARED/$_f36")" 'SYS_DATA_ROOT="${SYS_DATA_ROOT:-/usr/local/var/burrowee}"' "$_f36 must not default the data root to the 0.2 tree"
done
assert_contains "$(cat "$SHARED/run.sh")" 'LEGACY_SYS_CONFIG_ROOT="${LEGACY_SYS_CONFIG_ROOT:-/usr/local/etc/burrowee}"' "run.sh must keep the 0.2 config root as the LEGACY seam"
assert_contains "$(cat "$SHARED/run.sh")" 'LEGACY_SYS_DATA_ROOT="${LEGACY_SYS_DATA_ROOT:-/usr/local/var/burrowee}"' "run.sh must keep the 0.2 data root as the LEGACY seam"
assert_contains "$(cat "$SHARED/run.sh")" 'LEGACY_BIN_DIR="${LEGACY_BIN_DIR:-/usr/local/bin}"' "run.sh must keep the 0.2 exec root as the LEGACY seam"
# 36b. THE RUNNER HANDS THE LEGACY TRIPLE TO EVERY RUNG, the way it hands
#      $COMP_HOME. Nothing is exported by this case on purpose: the values the
#      rung sees can only have come through run_migration's own invocation
#      line, so a runner that stopped naming them there shows up as "unset".
#      The rung only WRITES the strings it was handed — the real 0.2 paths are
#      never opened.
t36="$TMP/t36"; kit "$t36" edge system installed-version $EDGE_BINS
cat > "$t36/migrations/echo_env.sh" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--applies" ]; then exit 0; fi
printf 'LEGACY_SYS_CONFIG_ROOT=%s\nLEGACY_SYS_DATA_ROOT=%s\nLEGACY_BIN_DIR=%s\n' \
    "${LEGACY_SYS_CONFIG_ROOT:-unset}" "${LEGACY_SYS_DATA_ROOT:-unset}" "${LEGACY_BIN_DIR:-unset}" > "$COMP_HOME/env.seen"
exit 0
EOF
chmod 0755 "$t36/migrations/echo_env.sh"
printf '# ledger\n0.3.0 echo_env.sh\n' > "$t36/migrations/ledger"
h36="$t36/home"; ch36="$h36/sys/etc/edge"; cd36="$h36/sys/var/edge"; mkdir -p "$ch36" "$cd36"
OUT="$(HOME="$h36" COMP_HOME="$ch36" COMP_DATA="$cd36" BIN_DIR="$h36/sys/bin" \
    LAUNCHD_DIR="$h36/no-launchd" SYSTEMD_DIR="$h36/no-systemd" \
    BURROWEE_LEGACY_HOME_PARENTS="$h36/nowhere" SUDO=/nonexistent-sudo \
    sh "$t36/migrations/run.sh" 2>&1)"; RC=$?
assert_eq "$RC" 2 "the env-echo rung must run"
assert_contains "$(cat "$ch36/env.seen" 2>/dev/null)" "LEGACY_SYS_CONFIG_ROOT=/usr/local/etc/burrowee" "run_migration must hand the rung the legacy config root it resolved"
assert_contains "$(cat "$ch36/env.seen" 2>/dev/null)" "LEGACY_SYS_DATA_ROOT=/usr/local/var/burrowee" "run_migration must hand the rung the legacy data root it resolved"
assert_contains "$(cat "$ch36/env.seen" 2>/dev/null)" "LEGACY_BIN_DIR=/usr/local/bin" "run_migration must hand the rung the legacy exec root it resolved"

# ---------------------------------------------------------------------------
# 37. THE 0.3.0 EXEC-ROOT SWEEP (sweep_stale_exec_root.sh). 0.3 moved the
#     binaries to /usr/local/burrowee/bin and linked the operator-typed names
#     back into /usr/local/bin; what 0.2 left there as REAL files is what this
#     rung removes — per name, and only a burrowee build with a trusted twin
#     in the new tree that no unit still names.
#
#     Fixture: $ob is the 0.2 exec root, $nb the 0.3 one. Both are under
#     $TMP; the twin-owner seam names this suite's own user, since the suite
#     cannot create root-owned files (and one case names somebody else, to
#     prove the seam is read).
# ---------------------------------------------------------------------------
# run_exec_sweep_ladder <kit> <home> [args…] — the ladder against a kit whose
# roots hang off <home>/sys and whose 0.2 exec root is <home>/old-bin.
run_exec_sweep_ladder() {
    _res_kit="$1"; _res_home="$2"; shift 2
    OUT="$(
        HOME="$_res_home" \
        COMP_HOME="$_res_home/sys/etc/edge" COMP_DATA="$_res_home/sys/var/edge" \
        SYS_CONFIG_ROOT="$_res_home/sys/etc" SYS_DATA_ROOT="$_res_home/sys/var" \
        BIN_DIR="$_res_home/sys/bin" \
        LEGACY_SYS_CONFIG_ROOT="$_res_home/old-etc" LEGACY_SYS_DATA_ROOT="$_res_home/old-var" \
        LEGACY_BIN_DIR="$_res_home/old-bin" \
        STALE_EXEC_ROOT_TWIN_OWNER="${EXEC_SWEEP_TWIN_OWNER:-$(id -un)}" \
        LAUNCHD_DIR="${EXEC_SWEEP_LAUNCHD_DIR:-$_res_home/no-launchd}" SYSTEMD_DIR="$_res_home/no-systemd" \
        BURROWEE_LEGACY_HOME_PARENTS="$_res_home/nowhere" SUDO=/nonexistent-sudo \
        sh "$_res_kit/migrations/run.sh" "$@" 2>&1
    )"
    RC=$?
}
# run_exec_sweep_rung <kit> <home> [args…] — the rung DIRECTLY, for the cases
# whose subject is a note the rung prints on a name it declines.
run_exec_sweep_rung() {
    _rer_kit="$1"; _rer_home="$2"; shift 2
    OUT="$(
        HOME="$_rer_home" COMP=edge \
        COMP_HOME="$_rer_home/sys/etc/edge" COMP_DATA="$_rer_home/sys/var/edge" \
        BIN_DIR="$_rer_home/sys/bin" LEGACY_BIN_DIR="$_rer_home/old-bin" \
        STALE_USER_BINS="$EDGE_BINS" \
        STALE_EXEC_ROOT_TWIN_OWNER="${EXEC_SWEEP_TWIN_OWNER:-$(id -un)}" \
        LAUNCHD_DIR="${EXEC_SWEEP_LAUNCHD_DIR:-$_rer_home/no-launchd}" SYSTEMD_DIR="$_rer_home/no-systemd" \
        BURROWEE_LEGACY_HOME_PARENTS="$_rer_home/nowhere" SUDO=/nonexistent-sudo \
        sh "$_rer_kit/migrations/sweep_stale_exec_root.sh" "$@" 2>&1
    )"
    RC=$?
}
# exec_sweep_kit <dir> — a system-scheme edge kit whose ledger carries only the
# 0.3.0 sweep row, with the 0.3 tree populated (twins) and the 0.2 exec root
# holding one of each shape: a real copy of ours (the updater — nobody types
# it, so the installer never links it), a real copy of ours under an
# operator-typed name (a host where the installer declined to link), a symlink
# the installer made, and an operator's own foreign file.
exec_sweep_kit() {
    kit "$1" edge system installed-version $EDGE_BINS
    printf '# ledger\n0.3.0 sweep_stale_exec_root.sh\n' > "$1/migrations/ledger"
    _esk_h="$1/home"
    mkdir -p "$_esk_h/sys/etc/edge" "$_esk_h/sys/var/edge"
    seed_twins "$_esk_h/sys/bin" $EDGE_BINS
    seed_ours "$_esk_h/old-bin" burrowee-edge-updater burrowee-edge-cli
    seed_foreign "$_esk_h/old-bin" burrowee
    ln -s "$_esk_h/sys/bin/burrowee-edge" "$_esk_h/old-bin/burrowee-edge"
}

# 37a. THE SWEEP, PER NAME: the two real copies of ours go, the link and the
#      foreign file stay, the receipt lands in the NEW config root.
t37="$TMP/t37"; exec_sweep_kit "$t37"; h37="$t37/home"
run_exec_sweep_ladder "$t37" "$h37"
assert_eq "$RC" 2 "no anchor + a pending exec-root sweep must exit 2 (migrations ran)"
assert_contains "$OUT" "sweep_stale_exec_root.sh applies: no recorded version" "the --applies probe must select the rung"
assert_gone "$h37/old-bin/burrowee-edge-updater" "the 0.2 real copy of the updater must be removed — nobody types it and the installer never links it"
assert_gone "$h37/old-bin/burrowee-edge-cli" "a 0.2 real copy under an operator-typed name is removed too — the installer declined to link on this host"
assert_present "$h37/old-bin/burrowee-edge" "the installer's symlink must survive"
assert_eq "$(readlink "$h37/old-bin/burrowee-edge")" "$h37/sys/bin/burrowee-edge" "and still point into the 0.3 tree"
assert_present "$h37/old-bin/burrowee" "an operator's own foreign file must survive"
assert_contains "$OUT" "removed stale 0.2 exec-root copy: $h37/old-bin/burrowee-edge-updater" "the rung must name what it removed"
assert_contains "$OUT" "kept $h37/old-bin/burrowee-edge — a symlink" "and say why the link was kept"
assert_contains "$OUT" "$h37/old-bin/burrowee carries no burrowee build stamp" "and why the foreign file was kept"
assert_present "$h37/sys/etc/edge/migration-receipts/sweep_stale_exec_root.sh@0.3.0.done" "the receipt must land in the NEW config root"
for b in $EDGE_BINS; do assert_present "$h37/sys/bin/$b" "the 0.3 tree must be untouched ($b)"; done

# 37a2. BIN_DIR UNSET (the updater track exports none). The runner must default a
#       `system` component's exec root to the 0.3 one, never to
#       ${PREFIX:-/usr/local}/bin — that equals $LEGACY_BIN_DIR, the library then
#       bails as "nothing replaced anything", the rung earns a receipt for a sweep
#       it never made, and the copies are stranded forever. Same fixture as 37a,
#       BIN_DIR and PREFIX deliberately absent, SYS_BIN_DIR seam pointing at the
#       0.3 tree. Mutation that reddens it: run.sh's BIN_DIR back to the PREFIX form.
t37a2="$TMP/t37a2"; exec_sweep_kit "$t37a2"; h37a2="$t37a2/home"
OUT="$(
    HOME="$h37a2" \
    COMP_HOME="$h37a2/sys/etc/edge" COMP_DATA="$h37a2/sys/var/edge" \
    SYS_CONFIG_ROOT="$h37a2/sys/etc" SYS_DATA_ROOT="$h37a2/sys/var" SYS_BIN_DIR="$h37a2/sys/bin" \
    LEGACY_SYS_CONFIG_ROOT="$h37a2/old-etc" LEGACY_SYS_DATA_ROOT="$h37a2/old-var" \
    LEGACY_BIN_DIR="$h37a2/old-bin" \
    STALE_EXEC_ROOT_TWIN_OWNER="$(id -un)" \
    LAUNCHD_DIR="$h37a2/no-launchd" SYSTEMD_DIR="$h37a2/no-systemd" \
    BURROWEE_LEGACY_HOME_PARENTS="$h37a2/nowhere" SUDO=/nonexistent-sudo \
    env -u BIN_DIR -u PREFIX sh "$t37a2/migrations/run.sh" 2>&1
)"; RC=$?
assert_eq "$RC" 2 "with BIN_DIR unset the runner must still resolve the 0.3 exec root and sweep"
assert_gone "$h37a2/old-bin/burrowee-edge-updater" "the stale 0.2 copy must be swept when BIN_DIR was never exported"
assert_present "$h37a2/old-bin/burrowee-edge" "the installer's symlink still survives"
assert_present "$h37a2/sys/etc/edge/migration-receipts/sweep_stale_exec_root.sh@0.3.0.done" "and the receipt records a sweep that actually happened"

# 37a3. THE UPDATER TRACK NEVER INHERITS THE LEGACY ANCHOR. The updater ladder
#       runs the same run.sh with a throwaway scratch $COMP_HOME and its own
#       ledger, where by contract the version gate never fires and every rung
#       falls through to --applies. The transitional 0.2-anchor fallback must
#       key on "$COMP_HOME IS the serve config tree", not merely on the scheme:
#       a scratch home that is empty on every run would otherwise adopt the
#       component's legacy anchor forever and gate the updater's rungs shut.
#       Mutation that reddens it: drop the `$COMP_HOME = $SYS_CONFIG_ROOT/$COMP`
#       conjunct from run.sh's fallback condition.
t37a3="$TMP/t37a3"; exec_sweep_kit "$t37a3"; h37a3="$t37a3/home"
mkdir -p "$h37a3/old-etc/edge" "$h37a3/scratch/etc/edge" "$h37a3/scratch/var/edge"
printf 'v0.2.19.2026.08.27.deadbeef\n' > "$h37a3/old-etc/edge/installed-version"
OUT="$(
    HOME="$h37a3" \
    COMP_HOME="$h37a3/scratch/etc/edge" COMP_DATA="$h37a3/scratch/var/edge" \
    SYS_CONFIG_ROOT="$h37a3/sys/etc" SYS_DATA_ROOT="$h37a3/sys/var" \
    BIN_DIR="$h37a3/sys/bin" \
    LEGACY_SYS_CONFIG_ROOT="$h37a3/old-etc" LEGACY_SYS_DATA_ROOT="$h37a3/old-var" \
    LEGACY_BIN_DIR="$h37a3/old-bin" \
    STALE_EXEC_ROOT_TWIN_OWNER="$(id -un)" \
    LAUNCHD_DIR="$h37a3/no-launchd" SYSTEMD_DIR="$h37a3/no-systemd" \
    BURROWEE_LEGACY_HOME_PARENTS="$h37a3/nowhere" SUDO=/nonexistent-sudo \
    sh "$t37a3/migrations/run.sh" 2>&1
)"; RC=$?
assert_lacks "$OUT" "TRANSITIONAL" "a scratch COMP_HOME must never adopt the component's legacy anchor"
assert_contains "$OUT" "sweep_stale_exec_root.sh applies: no recorded version" "the rung must fall through to --applies on the updater track"
assert_eq "$RC" 2 "and run"

# 37a4. THE KEEP-LIST. A name in $STALE_EXEC_ROOT_KEEP is never removed, however
#       the per-name evidence reads. The installers hand the ladder every
#       operator-typed name, because the rung runs BEFORE link_operator_bins has
#       made a single link: until one has, the real 0.2 file at that name is the
#       only copy anything reaches by the absolute path — the shared `burrowee`
#       dispatcher above all, which every co-installed component resolves there.
#       Mutation that reddens it: drop stale_exec_root_is_kept's call from
#       remove_stale_exec_root_bins (or from the --applies probe, for the second
#       half).
t37a4="$TMP/t37a4"; exec_sweep_kit "$t37a4"; h37a4="$t37a4/home"
seed_ours "$h37a4/old-bin" burrowee
OUT="$(
    HOME="$h37a4" \
    COMP_HOME="$h37a4/sys/etc/edge" COMP_DATA="$h37a4/sys/var/edge" \
    SYS_CONFIG_ROOT="$h37a4/sys/etc" SYS_DATA_ROOT="$h37a4/sys/var" \
    BIN_DIR="$h37a4/sys/bin" \
    LEGACY_SYS_CONFIG_ROOT="$h37a4/old-etc" LEGACY_SYS_DATA_ROOT="$h37a4/old-var" \
    LEGACY_BIN_DIR="$h37a4/old-bin" \
    STALE_EXEC_ROOT_KEEP="burrowee burrowee-edge burrowee-edge-cli" \
    STALE_EXEC_ROOT_TWIN_OWNER="$(id -un)" \
    LAUNCHD_DIR="$h37a4/no-launchd" SYSTEMD_DIR="$h37a4/no-systemd" \
    BURROWEE_LEGACY_HOME_PARENTS="$h37a4/nowhere" SUDO=/nonexistent-sudo \
    sh "$t37a4/migrations/run.sh" 2>&1
)"; RC=$?
assert_eq "$RC" 2 "the sweep still runs — the keep-list narrows it, it does not disable it"
assert_present "$h37a4/old-bin/burrowee" "a kept name must survive: no link has replaced it, so this is the only copy at that path"
assert_present "$h37a4/old-bin/burrowee-edge-cli" "a kept operator-typed name survives too"
assert_gone "$h37a4/old-bin/burrowee-edge-updater" "while a name NOT in the keep-list is still swept — per item, never per section"
assert_contains "$OUT" "kept $h37a4/old-bin/burrowee — no link was made at that name" "and the rung says why it kept it"

# 37a5. THE PROBE HONOURS IT TOO: with every removable name kept, --applies must
#       answer no, or the runner authorises a sweep that then declines and the
#       receipt closes the rung over copies it never touched.
t37a5="$TMP/t37a5"; exec_sweep_kit "$t37a5"; h37a5="$t37a5/home"
STALE_EXEC_ROOT_KEEP="burrowee burrowee-edge burrowee-edge-cli burrowee-edge-updater" \
    run_exec_sweep_rung "$t37a5" "$h37a5" --applies
assert_eq "$RC" 1 "--applies must answer no when every removable name is kept"

# 37a6. THE INSTALL-DESTINATION GUARD IS NORMALIZED. $LEGACY_BIN_DIR and
#       $BIN_DIR reach this library through independent seams, and a spelling
#       that differs only by a trailing or doubled slash names the SAME
#       directory. A raw string compare answers "different", the sweep then runs
#       against the install destination, and every name it decides `remove` for
#       is a binary the installer just placed — with a "twin" that is the very
#       file being deleted. Mutation that reddens it: put the raw
#       `[ "$LEGACY_BIN_DIR" != "$BIN_DIR" ]` compare back at either site.
t37a6="$TMP/t37a6"; exec_sweep_kit "$t37a6"; h37a6="$t37a6/home"
# The 0.3 tree IS the legacy dir here, spelled with a trailing slash on one side.
OUT="$(
    HOME="$h37a6" COMP=edge \
    COMP_HOME="$h37a6/sys/etc/edge" COMP_DATA="$h37a6/sys/var/edge" \
    BIN_DIR="$h37a6/sys/bin" LEGACY_BIN_DIR="$h37a6/sys/bin/" \
    STALE_USER_BINS="$EDGE_BINS" \
    STALE_EXEC_ROOT_TWIN_OWNER="$(id -un)" \
    LAUNCHD_DIR="$h37a6/no-launchd" SYSTEMD_DIR="$h37a6/no-systemd" \
    BURROWEE_LEGACY_HOME_PARENTS="$h37a6/nowhere" SUDO=/nonexistent-sudo \
    sh "$t37a6/migrations/sweep_stale_exec_root.sh" 2>&1
)"; RC=$?
assert_eq "$RC" 0 "a legacy dir that IS the destination is a no-op, not a failure"
for b in $EDGE_BINS; do assert_present "$h37a6/sys/bin/$b" "the install destination must be untouched ($b)"; done
# and the probe must agree, or --applies authorises a sweep the run then declines
OUT="$(
    HOME="$h37a6" COMP=edge \
    COMP_HOME="$h37a6/sys/etc/edge" COMP_DATA="$h37a6/sys/var/edge" \
    BIN_DIR="$h37a6/sys/bin" LEGACY_BIN_DIR="$h37a6/sys/bin/" \
    STALE_USER_BINS="$EDGE_BINS" \
    STALE_EXEC_ROOT_TWIN_OWNER="$(id -un)" \
    LAUNCHD_DIR="$h37a6/no-launchd" SYSTEMD_DIR="$h37a6/no-systemd" \
    BURROWEE_LEGACY_HOME_PARENTS="$h37a6/nowhere" SUDO=/nonexistent-sudo \
    sh "$t37a6/migrations/sweep_stale_exec_root.sh" --applies 2>&1
)"; RC=$?
assert_eq "$RC" 1 "--applies must answer no when the legacy dir IS the destination"

# 37b. IDEMPOTENT: the receipt skips it, and nothing else changes.
run_exec_sweep_ladder "$t37" "$h37"
assert_eq "$RC" 0 "a second run finds the receipt and applies nothing"
assert_contains "$OUT" "sweep_stale_exec_root.sh skipped: its receipt records it completed here" "the receipt must gate the second run"
assert_present "$h37/old-bin/burrowee-edge" "the link is still there after the second run"

# 37c. NOTHING TO SWEEP: no 0.2 exec root at all — a host born on 0.3.
t37c="$TMP/t37c"; exec_sweep_kit "$t37c"; h37c="$t37c/home"; rm -rf "$h37c/old-bin"
run_exec_sweep_ladder "$t37c" "$h37c"
assert_eq "$RC" 0 "with no 0.2 exec root the rung must decline"
assert_contains "$OUT" "sweep_stale_exec_root.sh skipped: no recorded version, and --applies does not recognise" "the probe must answer no"

# 37d. THE TWIN MUST BE TRUSTED. The new-tree copy is owned by somebody other
#      than the seam names: the old copy is kept and the reason is said. The
#      seam is what makes this drivable both ways without root.
t37d="$TMP/t37d"; exec_sweep_kit "$t37d"; h37d="$t37d/home"
EXEC_SWEEP_TWIN_OWNER="nobody-such-user-37d"; run_exec_sweep_rung "$t37d" "$h37d" --applies; unset EXEC_SWEEP_TWIN_OWNER
assert_eq "$RC" 1 "--applies must answer no when no twin is trusted"
EXEC_SWEEP_TWIN_OWNER="nobody-such-user-37d"; run_exec_sweep_rung "$t37d" "$h37d"; unset EXEC_SWEEP_TWIN_OWNER
assert_eq "$RC" 0 "the rung declines per name and exits 0"
assert_present "$h37d/old-bin/burrowee-edge-updater" "an untrusted twin must keep the 0.2 copy in place"
assert_contains "$OUT" "is not a regular file owned by nobody-such-user-37d" "and say which owner it wanted"

# 37e. A UNIT STILL NAMES IT: on the first 0.3 install the 0.2 updater unit
#      still names /usr/local/bin/burrowee-edge-updater, and unlinking a file a
#      supervisor may be running stops the daemon on macOS. Kept, and the
#      installer's later call (after the units moved) is what sweeps it.
t37e="$TMP/t37e"; exec_sweep_kit "$t37e"; h37e="$t37e/home"; mkdir -p "$h37e/launchd"
printf '<plist><dict><key>ProgramArguments</key><array><string>%s/old-bin/burrowee-edge-updater</string><string>run</string></array></dict></plist>\n' "$h37e" > "$h37e/launchd/com.burrowee.edge.updater.plist"
EXEC_SWEEP_LAUNCHD_DIR="$h37e/launchd"; run_exec_sweep_rung "$t37e" "$h37e"; unset EXEC_SWEEP_LAUNCHD_DIR
assert_eq "$RC" 0 "a unit-named file is a decline, not a failure: halting here would strand every row ordered after this one"
assert_present "$h37e/old-bin/burrowee-edge-updater" "a file a unit still names must not be unlinked"
assert_contains "$OUT" "$h37e/launchd/com.burrowee.edge.updater.plist still names $h37e/old-bin/burrowee-edge-updater" "and the unit must be named"
assert_gone "$h37e/old-bin/burrowee-edge-cli" "while a name no unit mentions is still swept — per item, never per section"

# 37f. --applies FAILS OPEN: a 0.2 exec root this process cannot read is
#      "still needed", never "nothing there".
if [ "$(id -u)" != 0 ]; then
    t37f="$TMP/t37f"; exec_sweep_kit "$t37f"; h37f="$t37f/home"
    chmod 000 "$h37f/old-bin"
    run_exec_sweep_rung "$t37f" "$h37f" --applies
    assert_eq "$RC" 0 "an unreadable 0.2 exec root must read as 'still needed'"
    run_exec_sweep_rung "$t37f" "$h37f"
    assert_eq "$RC" 0 "and the bare run declines out loud rather than failing the ladder"
    assert_contains "$OUT" "cannot read $h37f/old-bin" "saying it could not read"
    chmod 0755 "$h37f/old-bin"
fi

# 37g. NO TWIN: the 0.3 tree holds no copy of the name, so the 0.2 file is
#      the live install and stays.
t37g="$TMP/t37g"; exec_sweep_kit "$t37g"; h37g="$t37g/home"; rm -f "$h37g/sys/bin/burrowee-edge-updater"
run_exec_sweep_rung "$t37g" "$h37g"
assert_present "$h37g/old-bin/burrowee-edge-updater" "with no twin in the 0.3 tree the 0.2 copy is the live install"
assert_contains "$OUT" "kept $h37g/old-bin/burrowee-edge-updater — there is no $h37g/sys/bin/burrowee-edge-updater" "and the rung says so"

# 37h. BAD ARGUMENT — the same contract as its siblings.
run_exec_sweep_rung "$t37g" "$h37g" --bogus
assert_eq "$RC" 2 "an unknown argument must exit 2, like the other shared rungs"
assert_contains "$OUT" "unknown argument" "and say so"

# ---------------------------------------------------------------------------
# 38. THE TRANSITIONAL ANCHOR READ (spec §9.2). For a system-scheme component
#     the anchor lives inside the config tree 0.3 moves, so on the first 0.3
#     run the new root is empty and the ladder would re-probe every shipped
#     0.2.0 rung — and adopt_user_tree.sh, finding an empty destination and a
#     surviving per-user tree, would publish that STALE tree into the new
#     root, where never-overwrite makes it permanent. The runner reads the
#     0.2 anchor instead, once, read-only, and the numeric gate retires the
#     0.2.0 rows on the version the host really recorded.
# ---------------------------------------------------------------------------
# transitional_kit <dir> — edge's real ledger shape around the transition: the
# two 0.2.0 rows and the 0.3.0 sweep, a per-user tree the adoption WOULD take,
# the 0.2 config tree carrying an anchor, and an EMPTY 0.3 root.
transitional_kit() {
    adopt_kit "$1" edge system installed-version $EDGE_BINS
    printf '# ledger\n0.2.0 stale_user_bins.sh\n0.2.0 adopt_user_tree.sh\n0.3.0 sweep_stale_exec_root.sh\n' > "$1/migrations/ledger"
    _tk_h="$1/home"
    mkdir -p "$_tk_h/old-etc/edge/migration-receipts" "$_tk_h/stubs"
    echo "0.2.11.2026.08.20.deadbeef" > "$_tk_h/old-etc/edge/installed-version"
    seed_per_user_tree "$_tk_h/.burrowee/edge"
    seed_twins "$_tk_h/sys/bin" $EDGE_BINS
    make_cli_stub "$_tk_h/sys/bin" edge
    seed_ours "$_tk_h/old-bin" burrowee-edge-updater
    make_supervisor_stub "$_tk_h/stubs" kills
}
run_transitional_ladder() {
    _rtl_kit="$1"; _rtl_home="$2"; shift 2
    CLI_STUB_LOG="$_rtl_home/stubs/cli.log"
    OUT="$(
        HOME="$_rtl_home" \
        COMP_HOME="$_rtl_home/sys/etc/edge" COMP_DATA="$_rtl_home/sys/var/edge" \
        SYS_CONFIG_ROOT="$_rtl_home/sys/etc" SYS_DATA_ROOT="$_rtl_home/sys/var" \
        BIN_DIR="$_rtl_home/sys/bin" \
        LEGACY_SYS_CONFIG_ROOT="$_rtl_home/old-etc" LEGACY_SYS_DATA_ROOT="$_rtl_home/old-var" \
        LEGACY_BIN_DIR="$_rtl_home/old-bin" STALE_EXEC_ROOT_TWIN_OWNER="$(id -un)" \
        ROOT_HOME="$_rtl_home/root-home" \
        LAUNCHD_DIR="$_rtl_home/no-launchd" SYSTEMD_DIR="$_rtl_home/no-systemd" \
        BURROWEE_LEGACY_HOME_PARENTS="$_rtl_home/nowhere" SUDO_USER="" \
        SUDO="$_rtl_home/stubs/sudo" SYSTEMCTL="$_rtl_home/stubs/supervisor" LAUNCHCTL="$_rtl_home/stubs/supervisor" \
        CLI_STUB_LOG="$CLI_STUB_LOG" BURROWEE_MIGRATE_STOP_TIMEOUT=2 \
        sh "$_rtl_kit/migrations/run.sh" "$@" 2>&1
    )"
    RC=$?
}

# 38a. THE FIRST 0.3 RUN AGAINST A 0.2 HOST: the 0.2 anchor is read, the two
#      0.2.0 rows are retired by the gate, the adoption never runs, the
#      per-user tree is NOT published into the new root, only the 0.3.0 sweep
#      runs — and its receipt goes to the NEW root while the 0.2 tree is
#      exactly as it was.
t38="$TMP/t38"; transitional_kit "$t38"; h38="$t38/home"; ch38="$h38/sys/etc/edge"
if [ -d "$ch38" ]; then fail "case 38a fixture: the 0.3 config root must NOT exist yet"; fi
run_transitional_ladder "$t38" "$h38"
assert_eq "$RC" 2 "the 0.3.0 sweep must run (migrations ran)"
assert_contains "$OUT" "TRANSITIONAL: $ch38 holds no anchor and no receipts yet" "the runner must say it is reading the 0.2 anchor"
assert_contains "$OUT" "installed version 0.2.11.2026.08.20.deadbeef — compared as 0.2.11 (read from $h38/old-etc/edge/installed-version)" "and name where it read it from"
assert_contains "$OUT" "adopt_user_tree.sh skipped: installed 0.2.11.2026.08.20.deadbeef is not older than 0.2.0" "the numeric gate must retire the adoption on the recorded version"
assert_contains "$OUT" "stale_user_bins.sh skipped: installed 0.2.11.2026.08.20.deadbeef is not older than 0.2.0" "and the 0.2.0 sweep"
assert_gone "$ch38/identity/relay_ed.key" "the stale per-user tree must NOT have been published into the new root"
assert_lacks "$(cat "$CLI_STUB_LOG" 2>/dev/null)" "migrate --from" "the cli's migrate verb must never have been invoked"
assert_present "$h38/.burrowee/edge/identity/relay_ed.key" "and the per-user tree is untouched"
assert_present "$ch38/migration-receipts/sweep_stale_exec_root.sh@0.3.0.done" "the sweep's receipt lands in the NEW root"
assert_gone "$h38/old-etc/edge/migration-receipts/sweep_stale_exec_root.sh@0.3.0.done" "and never in the 0.2 tree"
assert_gone "$ch38/installed-version" "the runner writes no anchor — that is the installer's, after exit 2"
assert_eq "$(cat "$h38/old-etc/edge/installed-version")" "0.2.11.2026.08.20.deadbeef" "the 0.2 anchor is read-only"
assert_gone "$h38/old-bin/burrowee-edge-updater" "the 0.3.0 sweep did run"

# 38b. ONCE THE NEW ROOT HOLDS AN ANCHOR the 0.2 one is never consulted again
#      — transitional by construction, not by a flag.
t38b="$TMP/t38b"; transitional_kit "$t38b"; h38b="$t38b/home"; ch38b="$h38b/sys/etc/edge"; mkdir -p "$ch38b"
echo "0.3.0.2026.09.01.cafef00d" > "$ch38b/installed-version"
run_transitional_ladder "$t38b" "$h38b"
assert_eq "$RC" 0 "a 0.3.0 anchor in the new root closes every row"
assert_lacks "$OUT" "TRANSITIONAL" "the 0.2 anchor must not be consulted once the new root has one"
assert_contains "$OUT" "(read from $ch38b/installed-version)" "the anchor is read from the new root"
assert_present "$h38b/old-bin/burrowee-edge-updater" "and nothing ran"

# 38c. A NEW ROOT WITH RECEIPTS BUT NO ANCHOR is a 0.2 host whose first 0.3
#      ladder run died after an earlier rung receipted (record_migration creates
#      the directory; the anchor is written only at the end of the install).
#      Keying the fallback off receipts made that host re-probe the 0.2.0 rows
#      in fall-through mode and adopt a stale per-user tree over the copy.
t38c="$TMP/t38c"; transitional_kit "$t38c"; h38c="$t38c/home"; ch38c="$h38c/sys/etc/edge"; mkdir -p "$ch38c/migration-receipts"
run_transitional_ladder "$t38c" "$h38c"
assert_contains "$OUT" "TRANSITIONAL" "receipts land before the anchor does: a new root with receipts and no anchor is a 0.2 host mid-crossing, and its 0.2 anchor is still the evidence"

# 38d. A `user`-SCHEME COMPONENT IS UNAFFECTED, byte for byte: cli's tree
#      never moved, so a legacy anchor beside it means nothing.
t38d="$TMP/t38d"; kit "$t38d" cli user .installed-version $CLI_BINS
h38d="$t38d/home"; ch38d="$h38d/.burrowee/cli"; mkdir -p "$ch38d" "$h38d/old-etc/cli"
echo "0.2.11" > "$h38d/old-etc/cli/.installed-version"
OUT="$(HOME="$h38d" COMP_HOME="$ch38d" BIN_DIR="$h38d/usr-local-bin" LEGACY_SYS_CONFIG_ROOT="$h38d/old-etc" \
    LAUNCHD_DIR="$h38d/no-launchd" SYSTEMD_DIR="$h38d/no-systemd" BURROWEE_LEGACY_HOME_PARENTS="$h38d/nowhere" \
    SUDO=/nonexistent-sudo sh "$t38d/migrations/run.sh" 2>&1)"; RC=$?
assert_lacks "$OUT" "TRANSITIONAL" "a user-scheme component never reads a legacy anchor"
assert_contains "$OUT" "no installed version recorded ($ch38d/.installed-version is absent)" "cli reads its own tree, exactly as before"

# ---------------------------------------------------------------------------
echo "== $CASES checks, $FAILED failed =="
[ "$FAILED" = 0 ] || exit 1
