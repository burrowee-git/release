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
run_ladder "$t6" "$h6" "$ch6" "$h6/usr-local-bin"
assert_eq "$RC" 2 "a mixed directory still has ours to sweep"
assert_gone "$h6/.local/bin/burrowee-edge" "a stamped copy of ours must go"
assert_present "$h6/.local/bin/burrowee-edge-cli" "a REAL binary that is not ours must be left in place"
assert_contains "$OUT" "carries no burrowee build stamp" "the keep must say why"
assert_present "$h6/.local/bin/burrowee" "a symlink is not a binary this installer placed"
assert_contains "$OUT" "is a symlink" "the symlink keep must say why"

# ---------------------------------------------------------------------------
# 7. GUARD 4 — a unit file still naming the directory refuses the whole sweep
# ---------------------------------------------------------------------------
t7="$TMP/t7"; kit "$t7" edge root installed-version $EDGE_BINS
h7="$t7/home"; ch7="$h7/root-home/.burrowee/edge"; mkdir -p "$ch7" "$h7/systemd"
seed_ours "$h7/.local/bin" $EDGE_BINS
printf 'ExecStart=%s/.local/bin/burrowee-edge run\n' "$h7" > "$h7/systemd/burrowee-edge.service"
OUT="$(HOME="$h7" COMP_HOME="$ch7" BIN_DIR="$h7/usr-local-bin" \
    LAUNCHD_DIR="$h7/no-launchd" SYSTEMD_DIR="$h7/systemd" \
    BURROWEE_LEGACY_HOME_PARENTS="$h7/nowhere" SUDO=/nonexistent-sudo \
    sh "$t7/migrations/run.sh" 2>&1)"; RC=$?
assert_eq "$RC" 0 "a unit still naming the per-user dir must make the ladder a no-op, not a failure"
assert_contains "$OUT" "does not recognise" "the probe must decline for the same reason the sweep would"
for b in $EDGE_BINS; do
    assert_present "$h7/.local/bin/$b" "nothing may be removed while a unit names the directory"
done

# ---------------------------------------------------------------------------
# 8. PER-USER STATE IS NEVER TOUCHED — only binaries, by exact name
# ---------------------------------------------------------------------------
t8="$TMP/t8"; kit "$t8" edge root installed-version $EDGE_BINS
h8="$t8/home"; ch8="$h8/root-home/.burrowee/edge"; mkdir -p "$ch8" "$h8/.burrowee/edge/identity"
seed_ours "$h8/.local/bin" $EDGE_BINS
seed_ours "$h8/.local/bin" burrowee-edge-notes   # ours by stamp, NOT in $BINS
echo "secret" > "$h8/.burrowee/edge/identity/relay_ed.key"
echo '{"paired":true}' > "$h8/.burrowee/edge/console.json"
run_ladder "$t8" "$h8" "$ch8" "$h8/usr-local-bin"
assert_eq "$RC" 2 "the sweep must run"
assert_present "$h8/.burrowee/edge/identity/relay_ed.key" "per-user IDENTITY must never be touched by the binary sweep"
assert_present "$h8/.burrowee/edge/console.json" "per-user pairing state must never be touched"
assert_present "$h8/.local/bin/burrowee-edge-notes" "a name outside \$STALE_USER_BINS must survive — removal is by exact name, never by glob"

# ---------------------------------------------------------------------------
# 9. THE DISPATCHER RULE — kept while another burrowee component is still
#    installed per-user there; removed once nothing else of ours is left.
# ---------------------------------------------------------------------------
t9="$TMP/t9"; kit "$t9" cli user .installed-version $CLI_BINS
h9="$t9/home"; ch9="$h9/.burrowee/cli"; mkdir -p "$ch9"
seed_ours "$h9/.local/bin" $CLI_BINS burrowee-gateway
run_ladder "$t9" "$h9" "$ch9" "$h9/usr-local-bin"
assert_eq "$RC" 2 "the cli rung must run when its own names are stale"
assert_gone "$h9/.local/bin/burrowee-cli" "the cli's own names go"
assert_present "$h9/.local/bin/burrowee" "the dispatcher must stay while burrowee-gateway is still installed there"
assert_present "$h9/.local/bin/burrowee-gateway" "another component's binary is not the cli's to remove"
assert_contains "$OUT" "kept $h9/.local/bin/burrowee (dispatcher)" "keeping the dispatcher must be reported"

# 9b. with the co-installed component gone, the dispatcher goes too.
rm -f "$h9/.local/bin/burrowee-gateway"
rm -rf "$ch9/migration-receipts"
seed_ours "$h9/.local/bin" $CLI_BINS
run_ladder "$t9" "$h9" "$ch9" "$h9/usr-local-bin"
assert_eq "$RC" 2 "the rung must run again once the receipt is gone"
assert_gone "$h9/.local/bin/burrowee" "with nothing else of ours left, the shadowing dispatcher goes"

# 9c. an operator's OWN burrowee-* script must not pin the dispatcher forever.
rm -rf "$ch9/migration-receipts"
seed_ours "$h9/.local/bin" $CLI_BINS
seed_foreign "$h9/.local/bin" burrowee-notes
run_ladder "$t9" "$h9" "$ch9" "$h9/usr-local-bin"
assert_eq "$RC" 2 "the rung must run"
assert_gone "$h9/.local/bin/burrowee" "an operator's own burrowee-* file is not evidence a component is installed"
assert_present "$h9/.local/bin/burrowee-notes" "and it must itself be left alone"

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
printf 'stale_user_bins.sh\ncomp_home=/some/other/tree\n' > "$ch16/migration-receipts/stale_user_bins.sh.done"
run_ladder "$t16" "$h16" "$ch16" "$h16/usr-local-bin"
assert_eq "$RC" 2 "a receipt earned for another tree must not skip this one"
assert_contains "$OUT" "was earned for /some/other/tree" "the re-evaluation must name the foreign tree"

# 16b. and a receipt that records no tree at all falls through the same way.
t16b="$TMP/t16b"; kit "$t16b" edge root installed-version $EDGE_BINS
h16b="$t16b/home"; ch16b="$h16b/root-home/.burrowee/edge"; mkdir -p "$ch16b/migration-receipts"
seed_ours "$h16b/.local/bin" $EDGE_BINS
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
echo "== $CASES checks, $FAILED failed =="
[ "$FAILED" = 0 ] || exit 1
