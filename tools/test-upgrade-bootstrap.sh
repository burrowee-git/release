#!/bin/sh
# test-upgrade-bootstrap.sh — prove the hosted upgrade bootstrap, OFFLINE.
#
#   curl -fsSL https://release.burrowee.com/<comp>/upgrade.sh | sh -s -- 0.2.0
#
# <comp>/upgrade.sh is <comp>/install.sh plus one step: same template, same
# baked pubkey, same pinned preflight, same version floor, same verify → unzip →
# run the inner installer — and then `migrations/upgrade.sh <floor>` out of the
# SAME verified kit. This script drives the RENDERED artifact end to end against
# a fabricated local release and asserts the four things that can silently be
# wrong about it:
#
#   1. ORDER + MODE — upgrade.sh runs the installer and THEN the migration; a
#      rendered install.sh runs only the installer. The mode split is real.
#   2. THE ARGUMENT — it is the migration FLOOR, handed to the kit's own
#      forcing entry VERBATIM, and it never filters WHICH release resolves.
#      Absent, the floor is derived from the KIT'S OWN LEDGER (its newest
#      target), NEVER from the release tag: the fixture's release line (0.2.1)
#      deliberately differs from its ladder top (0.2.0), so any tag-derived
#      floor fails the assertion by construction. A malformed or extra
#      argument is refused BEFORE the network.
#   3. THE EXIT MAPPING — the ladder's five-value contract, in which 2 means
#      RUNS HAPPENED and is a SUCCESS. A bootstrap that treats non-zero as
#      failure reports every real upgrade as broken.
#   4. THE PRE-INVOCATION KIT CHECKS — a kit missing (or shipping empty) ANY
#      of migrations/upgrade.sh, migrations/run.sh, or migrations/ledger
#      refuses BY NAME, before the ladder is invoked, naming the component and
#      the version just installed — never succeeding silently.
#
# IT NEVER TOUCHES THE WORKING TREE. tools/test-version-floor.sh,
# test-tag-binding.sh and test-r2-fallback.sh all re-render the CHECKED-IN
# bootstraps with an ephemeral key and restore them only on a clean exit — which
# is how a TEST-keyed bootstrap ends up staged. This script instead copies the
# templates + generator into a scratch root and renders THERE, so a failed run
# leaves nothing behind to restore. Nothing is installed anywhere: the "inner
# installer" and the "ladder" are stubs that append to a log and exit with a
# code the scenario chose.
#
# POSIX sh on purpose, and run under bash AND dash: macOS /bin/sh is bash 3.2,
# which is why a fatal /dev/tty bug shipped undetected in two installers. The
# rendered bootstrap is additionally executed by every sh-like shell on the box.
#
# Needs: minisign, zip, unzip, curl, python3, and shasum or sha256sum.
set -eu

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
PORT="${UPGRADE_TEST_PORT:-8841}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n\342\234\227 UPGRADE-BOOTSTRAP TEST FAILED: '; printf '%b\n' "$*" >&2; exit 1; }
pass() { printf '  OK: %s\n' "$*"; }

# ---- work dir + cleanup -----------------------------------------------------
# INT and TERM as well as EXIT: a suite killed between the server start and the
# end of the run would otherwise leave a python3 listening on the port and make
# every later run fail on a stale server it did not start.
W="$(mktemp -d "${TMPDIR:-/tmp}/test-upgrade-bootstrap-XXXXXX")"
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
    rm -rf "$W"
}
trap cleanup EXIT INT TERM

# ---- (0) tools --------------------------------------------------------------
for t in minisign zip unzip curl python3; do
    command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"
done
if command -v sha256sum >/dev/null 2>&1; then SUMS="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SUMS="shasum -a 256"
else die "neither sha256sum nor shasum found"; fi

case "$(uname -s)" in Darwin) OS=darwin ;; Linux) OS=linux ;; *) die "unsupported OS $(uname -s)" ;; esac
case "$(uname -m)" in arm64 | aarch64) ARCH=arm64 ;; x86_64 | amd64) ARCH=amd64 ;; *) die "unsupported arch $(uname -m)" ;; esac

COMP=gateway
# The release line (0.2.1) and the fixture kit's ladder top (0.2.0) DIFFER on
# purpose: the default floor must come from the kit's own ledger, so a bootstrap
# that derives it from the resolved tag hands the ladder 0.2.1 and fails the
# no-argument assertion by construction. This is the exact release shape that
# broke the retired tag-derived design: a line that moved past an unchanged
# ladder.
STAMP="v0.2.1.2026.08.17.4e43c2ed"
TAG="${COMP}/${STAMP}"
MINV="0.2.1"
LEDGER_TOP="0.2.0"
ZIP="burrowee-${COMP}-${OS}-${ARCH}.zip"

# ---- (1) render into a SCRATCH root -----------------------------------------
say "RENDER: gen-bootstraps.sh into a scratch root (the worktree is not touched)"
mkdir -p "$W/repo/tools" "$W/home"
for f in bootstrap.template.sh relay-bootstrap.template.sh preflight.template.sh gen-bootstraps.sh; do
    cp "$REPO_ROOT/tools/$f" "$W/repo/tools/$f"
done
# tools/modules/ — gen-bootstraps.sh expands @INCLUDE:<name>@ from
# MODDIR="$ROOT/tools/modules" at render time, so the scratch root needs its
# own copy or every include fails closed before anything is rendered.
cp -R "$REPO_ROOT/tools/modules" "$W/repo/tools/modules"
minisign -G -W -p "$W/test.pub" -s "$W/test.key" >/dev/null 2>&1 \
    || die "could not generate an ephemeral minisign keypair"
BURROWEE_PUBKEY_FILE="$W/test.pub" BURROWEE_MIN_VERSION="$MINV" \
    sh "$W/repo/tools/gen-bootstraps.sh" >/dev/null \
    || die "gen-bootstraps.sh failed in the scratch root"

INSTALL_SH="$W/repo/$COMP/install.sh"
UPGRADE_SH="$W/repo/$COMP/upgrade.sh"
[ -f "$UPGRADE_SH" ] || die "gen-bootstraps.sh rendered no $COMP/upgrade.sh — the hosted URL would 404"
pass "rendered $COMP/{install,upgrade,preflight}.sh under $W/repo"

# ---- (2) the two renders differ in MODE and in nothing else that matters -----
say "BAKE: upgrade.sh carries install.sh's trust anchors, and only the mode differs"
baked() { sed -n "s/^$2=\"\\(.*\\)\"\$/\\1/p" "$1"; }
for name in PUBKEY MIN_VERSION PREFLIGHT_SHA256; do
    a="$(baked "$INSTALL_SH" "$name")"
    b="$(baked "$UPGRADE_SH" "$name")"
    [ -n "$a" ] || die "$COMP/install.sh bakes no $name"
    [ "$a" = "$b" ] || die "$name differs between the two renders: install='$a' upgrade='$b'"
done
[ "$(baked "$INSTALL_SH" MODE)" = install ] || die "install.sh did not render as MODE=install"
[ "$(baked "$UPGRADE_SH" MODE)" = upgrade ] || die "upgrade.sh did not render as MODE=upgrade"
pass "same pubkey, floor and preflight pin; MODE=install vs MODE=upgrade"

say "SYNTAX: the rendered artifacts parse under every sh on this box"
SHELLS=""
for s in sh dash bash; do
    command -v "$s" >/dev/null 2>&1 || continue
    SHELLS="$SHELLS $s"
    "$s" -n "$UPGRADE_SH" || die "$s -n failed on the rendered $COMP/upgrade.sh"
    "$s" -n "$INSTALL_SH" || die "$s -n failed on the rendered $COMP/install.sh"
done
[ -n "$SHELLS" ] || die "no sh-like shell found"
pass "parsed by:$SHELLS"

# ---- (3) fabricate a signed local release -----------------------------------
# FIVE kits, same stamp, served from five paths: one complete, one with no
# migrations/ at all, and three each missing (or shipping empty) exactly one of
# the files the bootstrap must pre-check by name. The stubs record what ran, in
# what order, and with which arguments — argc is recorded separately from arg1
# so "passed nothing" and "passed the empty string" are different observations,
# which is exactly the difference between deriving the default floor from the
# kit's ledger and forwarding the operator's (absent) argument.
say "FABRICATE: a signed local release, complete and broken kits"
mkdir -p "$W/kit/migrations" "$W/nokit"
cat > "$W/kit/install.sh" <<'INNER'
#!/bin/sh
printf 'install version=%s\n' "${BURROWEE_VERSION:-}" >> "$UB_LOG"
exit "${UB_INSTALL_CODE:-0}"
INNER
# The fake ladder: a forcing entry that records the exact argv it received. The
# real one would exec run.sh --assume-below <floor> --rerun-recorded; here the
# recorded argv IS the assertion surface, so nothing else runs.
cat > "$W/kit/migrations/upgrade.sh" <<'LADDER'
#!/bin/sh
printf 'migrate argc=%s arg1=%s\n' "$#" "${1:-}" >> "$UB_LOG"
exit "${UB_LADDER_CODE:-0}"
LADDER
# run.sh is never invoked by the bootstrap (the forcing entry owns that), but
# its presence is pre-checked by name, and a recording stub proves it stays
# un-run in every scenario below (no "runner" line ever appears in the log).
cat > "$W/kit/migrations/run.sh" <<'RUNSH'
#!/bin/sh
printf 'runner argv=%s\n' "$*" >> "$UB_LOG"
exit 0
RUNSH
# The kit's ledger. The newest target (0.2.0) is deliberately NOT the first row
# and two rows share it: the default floor must be the numeric-newest target,
# not the first or last row, and the comment must be ignored.
cat > "$W/kit/migrations/ledger" <<'LEDGER'
# fixture ledger — newest target is not the first row on purpose
0.1.0 v0_0_to_v0_1.sh
0.2.0 v0_1_to_v0_2.sh
0.2.0 v0_2_stale_user_bins.sh
LEDGER
cp "$W/kit/install.sh" "$W/nokit/install.sh"
# A kit whose forcing entry is PRESENT BUT EMPTY. This is not a hypothetical
# fixture: `sh <script>` exits 2 when it cannot open or read the script — dash,
# and therefore /bin/sh on Debian and Ubuntu — and 2 is the ladder's own code
# for "rungs ran, success". A bootstrap that invokes the ladder without first
# checking the file is readable reports a broken kit as a completed migration,
# and nothing downstream can tell the two apart afterwards.
mkdir -p "$W/emptykit/migrations"
cp "$W/kit/install.sh" "$W/emptykit/install.sh"
cp "$W/kit/migrations/run.sh" "$W/emptykit/migrations/run.sh"
cp "$W/kit/migrations/ledger" "$W/emptykit/migrations/ledger"
: > "$W/emptykit/migrations/upgrade.sh"
# A kit with no run.sh: the forcing entry execs it, so its absence must refuse
# by name before anything is invoked.
mkdir -p "$W/norunkit/migrations"
cp "$W/kit/install.sh" "$W/norunkit/install.sh"
cp "$W/kit/migrations/upgrade.sh" "$W/norunkit/migrations/upgrade.sh"
cp "$W/kit/migrations/ledger" "$W/norunkit/migrations/ledger"
# A kit with no ledger: the default floor is read out of it, and the runner
# reads it regardless of the floor's origin — so it too must refuse by name.
mkdir -p "$W/noledgerkit/migrations"
cp "$W/kit/install.sh" "$W/noledgerkit/install.sh"
cp "$W/kit/migrations/upgrade.sh" "$W/noledgerkit/migrations/upgrade.sh"
cp "$W/kit/migrations/run.sh" "$W/noledgerkit/migrations/run.sh"
chmod +x "$W/kit/install.sh" "$W/kit/migrations/upgrade.sh" "$W/kit/migrations/run.sh" \
    "$W/nokit/install.sh" "$W/emptykit/install.sh" "$W/emptykit/migrations/upgrade.sh" \
    "$W/norunkit/install.sh" "$W/norunkit/migrations/upgrade.sh" \
    "$W/noledgerkit/install.sh" "$W/noledgerkit/migrations/upgrade.sh"

sign_kit() {
    # sign_kit <src-dir> <serve-subdir> <zip-args...>
    _src="$1"
    _sub="$2"
    shift 2
    mkdir -p "$W/serve/$_sub"
    ( cd "$_src" && zip -qr "$W/serve/$_sub/$ZIP" "$@" ) || die "zip failed for $_sub"
    ( cd "$W/serve/$_sub" && $SUMS "$ZIP" > SHA256SUMS.txt ) || die "checksum failed for $_sub"
    ( cd "$W/serve/$_sub" \
        && minisign -S -m SHA256SUMS.txt -s "$W/test.key" \
            -c "burrowee test release" -t "burrowee $COMP $STAMP" >/dev/null 2>&1 ) \
        || die "minisign signing failed for $_sub"
}
sign_kit "$W/kit" kit install.sh migrations
sign_kit "$W/nokit" nokit install.sh
sign_kit "$W/emptykit" emptykit install.sh migrations
sign_kit "$W/norunkit" norunkit install.sh migrations
sign_kit "$W/noledgerkit" noledgerkit install.sh migrations
for m in upgrade.sh run.sh ledger; do
    unzip -Z1 "$W/serve/kit/$ZIP" | grep -qx "migrations/$m" \
        || die "the fabricated kit does not actually carry migrations/$m — the fixture proves nothing"
done
unzip -Z1 "$W/serve/nokit/$ZIP" | grep -q 'migrations/' \
    && die "the fabricated no-ladder kit carries a migrations/ member"
unzip -Z1 "$W/serve/norunkit/$ZIP" | grep -qx 'migrations/run.sh' \
    && die "the fabricated no-run.sh kit carries migrations/run.sh — the fixture proves nothing"
unzip -Z1 "$W/serve/noledgerkit/$ZIP" | grep -qx 'migrations/ledger' \
    && die "the fabricated no-ledger kit carries migrations/ledger — the fixture proves nothing"
pass "five signed kits under $W/serve"

# ---- (4) serve --------------------------------------------------------------
say "SERVE: 127.0.0.1:$PORT"
( cd "$W/serve" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
SERVER_PID=$!
i=0
until curl -fsS "http://127.0.0.1:$PORT/kit/$ZIP" -o /dev/null 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || die "http server did not come up on $PORT"
    sleep 0.1
done
BASE_URL="http://127.0.0.1:$PORT"
pass "server up"

# ---- (5) the scenarios ------------------------------------------------------
# run_boot <shell> <script> <serve-subdir> [args…] — runs the rendered bootstrap
# with a fresh log and captures BOTH its output and its exit code. The code is
# read straight off the command substitution, never after a pipe: `cmd | tee`
# would hand back tee's status and every exit-mapping assertion below would be
# reporting on a command it never measured.
RUN_OUT=""
RUN_CODE=0
INSTALL_CODE=0
LADDER_CODE=0
run_boot() {
    _sh="$1"
    _script="$2"
    _sub="$3"
    shift 3
    : > "$W/log"
    set +e
    RUN_OUT="$(
        UB_LOG="$W/log" \
            UB_INSTALL_CODE="$INSTALL_CODE" \
            UB_LADDER_CODE="$LADDER_CODE" \
            BURROWEE_SKIP_PREFLIGHT=1 \
            BURROWEE_GH_PROXY= \
            BURROWEE_DL_BASE="$BASE_URL/$_sub" \
            BURROWEE_GATEWAY_VERSION="$TAG" \
            HOME="$W/home" \
            "$_sh" "$_script" "$@" 2>&1
    )"
    RUN_CODE=$?
    set -e
}

want_code() {
    [ "$RUN_CODE" = "$1" ] \
        || die "$2: exit $RUN_CODE, want $1\n--- output ---\n$RUN_OUT\n--- log ---\n$(cat "$W/log")"
}
want_log() {
    _got="$(cat "$W/log")"
    [ "$_got" = "$1" ] \
        || die "$2: log is\n$_got\nwant\n$1\n--- output ---\n$RUN_OUT"
}
want_out() {
    case "$RUN_OUT" in
    *"$1"*) : ;;
    *) die "$2: output does not mention '$1'\n--- output ---\n$RUN_OUT" ;;
    esac
}
want_no_out() {
    case "$RUN_OUT" in
    *"$1"*) die "$2: output mentions '$1' and must not\n--- output ---\n$RUN_OUT" ;;
    *) : ;;
    esac
}

INSTALLED="install version=$TAG"
migrated() { printf 'migrate argc=1 arg1=%s' "$1"; }

for SH in $SHELLS; do
    say "SCENARIOS under $SH"

    # (5a) The mode split is real, not cosmetic.
    INSTALL_CODE=0 LADDER_CODE=0
    run_boot "$SH" "$INSTALL_SH" kit
    want_code 0 "[$SH] install.sh"
    want_log "$INSTALLED" "[$SH] install.sh must run ONLY the inner installer"
    pass "[$SH] install.sh runs the installer and nothing else"

    # (5b) upgrade.sh runs the installer, THEN the migration, and the argument
    # reaches the kit's forcing entry verbatim.
    run_boot "$SH" "$UPGRADE_SH" kit "$LEDGER_TOP"
    want_code 0 "[$SH] upgrade.sh $LEDGER_TOP"
    want_log "$INSTALLED
$(migrated "$LEDGER_TOP")" "[$SH] upgrade.sh must run the installer first and the ladder second"
    want_out "migration floor $LEDGER_TOP (your argument)" "[$SH] an operator floor must be announced as the operator's"
    pass "[$SH] upgrade.sh: install then migrate, in that order, floor verbatim"

    # (5c) With NO argument the floor comes from the KIT'S OWN LEDGER — its
    # newest target, 0.2.0 — never from the release tag. The fixture's release
    # line is 0.2.1, so a tag-derived floor CANNOT satisfy this log: the two
    # sources disagree by construction. A bootstrap that forwarded the
    # operator's (absent) argument would hand the ladder an empty string, which
    # argc=1 arg1=0.2.0 also rules out.
    run_boot "$SH" "$UPGRADE_SH" kit
    want_code 0 "[$SH] upgrade.sh (no argument)"
    want_log "$INSTALLED
$(migrated "$LEDGER_TOP")" "[$SH] the default floor must be the ledger's newest target, not the release line"
    want_out "this kit's newest ladder target" "[$SH] the default floor must be announced as the ledger's"
    pass "[$SH] no argument: the floor is the kit ledger's newest target (0.2.0, not 0.2.1)"

    # (5c') An explicit floor BELOW the ladder top passes through verbatim —
    # the backfill case the old equality cross-check used to break.
    run_boot "$SH" "$UPGRADE_SH" kit "0.1.0"
    want_code 0 "[$SH] upgrade.sh 0.1.0"
    want_log "$INSTALLED
$(migrated "0.1.0")" "[$SH] an operator floor must reach the kit verbatim"
    pass "[$SH] a floor below the ladder top is handed to the kit verbatim"

    # (5c'') A floor ABOVE the ladder top is NOT the bootstrap's to refuse: it
    # goes to the kit verbatim, and the KIT's own cross-check is the judge (the
    # real forcing entry exits 64 on it; the recording stub here proves the
    # bootstrap forwarded rather than filtered).
    run_boot "$SH" "$UPGRADE_SH" kit "0.3.0"
    want_code 0 "[$SH] upgrade.sh 0.3.0 (stub kit accepts)"
    want_log "$INSTALLED
$(migrated "0.3.0")" "[$SH] the bootstrap must forward an above-top floor, not pre-judge it"
    pass "[$SH] an above-ladder-top floor is forwarded — the kit is the judge"

    # (5c''') A release-stamp-shaped argument is normalized to its X.Y.Z before
    # it is handed on, same as the retired line argument was.
    run_boot "$SH" "$UPGRADE_SH" kit "v0.1.0.2026.01.01.deadbeef"
    want_code 0 "[$SH] upgrade.sh <stamp>"
    want_log "$INSTALLED
$(migrated "0.1.0")" "[$SH] a stamp-shaped floor must normalize to its X.Y.Z"
    pass "[$SH] a stamp-shaped floor normalizes to 0.1.0"

    # (5d) THE EXIT MAPPING. 2 = rungs ran = SUCCESS.
    LADDER_CODE=2
    run_boot "$SH" "$UPGRADE_SH" kit "$LEDGER_TOP"
    want_code 0 "[$SH] ladder exit 2 must be a bootstrap SUCCESS"
    want_out "migration ladder exited 2" "[$SH] the mapping must be printed"
    pass "[$SH] ladder 2 (rungs ran) -> bootstrap 0"

    LADDER_CODE=0
    run_boot "$SH" "$UPGRADE_SH" kit "$LEDGER_TOP"
    want_code 0 "[$SH] ladder exit 0"
    want_out "forcing the state migrations from floor $LEDGER_TOP up" "[$SH] the forcing line must name the floor"
    pass "[$SH] ladder 0 (nothing applied) -> bootstrap 0"

    LADDER_CODE=1
    run_boot "$SH" "$UPGRADE_SH" kit "$LEDGER_TOP"
    want_code 1 "[$SH] ladder exit 1 must FAIL the bootstrap"
    want_out "migration ladder exited 1" "[$SH] the mapping must be printed"
    pass "[$SH] ladder 1 (refused/failed) -> bootstrap 1"

    LADDER_CODE=3
    run_boot "$SH" "$UPGRADE_SH" kit "$LEDGER_TOP"
    want_code 3 "[$SH] ladder exit 3 must reach the caller"
    pass "[$SH] ladder 3 (receipt lost) -> bootstrap 3"

    LADDER_CODE=64
    run_boot "$SH" "$UPGRADE_SH" kit "$LEDGER_TOP"
    want_code 64 "[$SH] ladder exit 64 must reach the caller"
    pass "[$SH] ladder 64 (usage) -> bootstrap 64"
    LADDER_CODE=0

    # (5e) The migration runs ONLY if the install succeeded.
    INSTALL_CODE=1
    run_boot "$SH" "$UPGRADE_SH" kit "$LEDGER_TOP"
    [ "$RUN_CODE" != 0 ] || die "[$SH] a failed inner installer left the bootstrap green"
    want_log "$INSTALLED" "[$SH] the ladder must not run after a failed install"
    pass "[$SH] a failed installer stops the run before the migration"
    INSTALL_CODE=0

    # (5f) A kit missing any pre-checked file: refuse BY NAME, naming the
    # component and the version, BEFORE the ladder is invoked.
    #
    # "non-zero + names the component" is NOT enough on its own to prove this:
    # a bootstrap with no check at all would `sh ./migrations/upgrade.sh` into a
    # missing file, exit 127, map that to 1, and satisfy both — while printing a
    # shell error instead of saying what is wrong. So the refusal must also be
    # SPECIFIC, and must arrive BEFORE the ladder is invoked at all, which the
    # absence of the exit-mapping line is the observable proof of.
    run_boot "$SH" "$UPGRADE_SH" nokit "$LEDGER_TOP"
    [ "$RUN_CODE" != 0 ] || die "[$SH] a kit with no migrations/upgrade.sh succeeded silently"
    want_out "ships no usable migrations/upgrade.sh" "[$SH] the no-ladder refusal must say what is missing"
    want_out "$COMP" "[$SH] the no-ladder refusal must name the component"
    want_out "$TAG" "[$SH] the no-ladder refusal must name the version just installed"
    want_no_out "migration ladder exited" "[$SH] the refusal must come BEFORE the ladder is invoked, not from its failure"
    want_log "$INSTALLED" "[$SH] the installer still ran before the no-ladder refusal"
    pass "[$SH] a kit with no ladder refuses, naming the component and version"

    run_boot "$SH" "$INSTALL_SH" nokit
    want_code 0 "[$SH] install.sh against a kit with no ladder is unaffected"
    pass "[$SH] install.sh does not care that the kit has no ladder"

    # A ladder that is PRESENT but unreadable/empty must refuse too — `sh` on an
    # unopenable script exits 2, which is the ladder's own success code. Without
    # the readable/non-empty pre-check this run reports a completed migration.
    run_boot "$SH" "$UPGRADE_SH" emptykit "$LEDGER_TOP"
    [ "$RUN_CODE" != 0 ] || die "[$SH] an EMPTY migrations/upgrade.sh was reported as a successful migration (sh exits 2 on a script it cannot read, which is the ladder's success code)"
    want_out "ships no usable migrations/upgrade.sh" "[$SH] an unusable ladder must refuse for the same stated reason"
    want_no_out "migration ladder exited" "[$SH] an unusable ladder must be caught before it is invoked"
    pass "[$SH] an empty/unreadable ladder refuses instead of passing as exit 2"

    # A kit with no run.sh: the forcing entry execs it, so it is pre-checked by
    # name too — an operator floor does not skip the check.
    run_boot "$SH" "$UPGRADE_SH" norunkit "$LEDGER_TOP"
    [ "$RUN_CODE" != 0 ] || die "[$SH] a kit with no migrations/run.sh succeeded silently"
    want_out "ships no usable migrations/run.sh" "[$SH] the no-run.sh refusal must name run.sh"
    want_no_out "migration ladder exited" "[$SH] the no-run.sh refusal must come before the ladder is invoked"
    want_log "$INSTALLED" "[$SH] the installer still ran before the no-run.sh refusal"
    pass "[$SH] a kit with no run.sh refuses by name"

    # A kit with no ledger refuses by name — with no argument (the default
    # floor is read out of the ledger) AND with one (the runner reads the
    # ledger regardless of where the floor came from).
    run_boot "$SH" "$UPGRADE_SH" noledgerkit
    [ "$RUN_CODE" != 0 ] || die "[$SH] a kit with no migrations/ledger succeeded silently"
    want_out "ships no usable migrations/ledger" "[$SH] the no-ledger refusal must name the ledger"
    want_no_out "migration ladder exited" "[$SH] the no-ledger refusal must come before the ladder is invoked"
    pass "[$SH] a kit with no ledger refuses by name (no argument)"

    run_boot "$SH" "$UPGRADE_SH" noledgerkit "$LEDGER_TOP"
    [ "$RUN_CODE" != 0 ] || die "[$SH] an operator floor skipped the missing-ledger check"
    want_out "ships no usable migrations/ledger" "[$SH] the no-ledger refusal must name the ledger even with a floor given"
    pass "[$SH] a kit with no ledger refuses by name (floor given)"

    # (5g) THE COMMAND LINE, refused before the network is touched. "using
    # pinned version" is the first thing the resolution step prints, so its
    # absence is the proof that nothing was resolved or downloaded.
    run_boot "$SH" "$UPGRADE_SH" kit "$LEDGER_TOP" extra
    want_code 64 "[$SH] a second argument must be refused"
    want_log "" "[$SH] a second argument must be refused before anything runs"
    want_no_out "using pinned version" "[$SH] refused arguments must not reach the network"
    pass "[$SH] a second argument is refused before the network"

    run_boot "$SH" "$UPGRADE_SH" kit "0.2.x"
    want_code 64 "[$SH] a malformed version must be refused"
    want_log "" "[$SH] a malformed version must be refused before anything runs"
    want_no_out "using pinned version" "[$SH] refused arguments must not reach the network"
    pass "[$SH] a malformed version is refused before the network"

    run_boot "$SH" "$INSTALL_SH" kit "$LEDGER_TOP"
    want_code 64 "[$SH] install.sh takes no arguments and must reject them"
    want_log "" "[$SH] install.sh must reject an argument before installing"
    pass "[$SH] install.sh rejects arguments rather than discarding them"

    # (5h) Explicit help is stdout + exit 0 (a refusal is stderr + non-zero).
    run_boot "$SH" "$UPGRADE_SH" kit --help
    want_code 0 "[$SH] --help must exit 0"
    want_out "usage" "[$SH] --help must print a usage"
    want_out "floor" "[$SH] --help must describe the argument as the floor"
    want_log "" "[$SH] --help must install nothing"
    pass "[$SH] --help is stdout, exit 0, installs nothing"
done

# ---- (6) RESOLVER: the argument does NOT filter the resolution ---------------
# The scenarios above pin the tag through BURROWEE_<COMP>_VERSION, so they never
# exercise the resolver. Extract the shipped resolution blocks from the RENDERED
# upgrade.sh and drive them against a stub $CURL — the same hermetic approach
# tools/test-version-floor.sh takes, and still no network. The retired design
# made the argument PIN the resolved line; now it is the migration floor and
# must leave the resolution alone: with 0.3.0 and 0.2.0 published and 0.2.0
# named, the resolved tag is 0.3.0's (and 0.2.0 goes to the ladder as the
# floor, which the recording-stub scenarios above already proved).
say "RESOLVER: extracting the shipped resolution blocks from the rendered upgrade.sh"
sed -n '/^# BEGIN release-resolver/,/^# END release-resolver/p' "$UPGRADE_SH" > "$W/resolver.sh"
sed -n '/^# BEGIN version-floor/,/^# END version-floor/p' "$UPGRADE_SH" > "$W/floor.sh"
sed -n '/^# BEGIN version-resolve/,/^# END version-resolve/p' "$UPGRADE_SH" > "$W/resolve.sh"
for b in resolver floor resolve; do
    grep -q '^# END' "$W/$b.sh" || die "could not extract the $b block from the rendered upgrade.sh (markers missing or renamed)"
done

# FLOOR is set the way the shipped mode-args block would set it from the
# operator's argument. The blocks must never read it: if resolution-pinning is
# ever reintroduced, the floor-named case below resolves 0.2.0's tag instead of
# 0.3.0's and fails.
cat > "$W/resolve-run.sh" <<'RUNNER'
#!/bin/sh
set -eu
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { :; }
ok()   { :; }
COMP=gateway
REPO=burrowee-git/release
DL_BASE=""
BURROWEE_GATEWAY_VERSION=""
GH_PROXIES=""
CONSOLE_URL="https://console.invalid"
MIN_VERSION="${STUB_MIN}"
FLOOR="${STUB_ARG}"
CURL=stub_curl
stub_curl() {
    _out=""; _hdr=""; _url=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -o) _out="$2"; shift 2 ;;
            -D) _hdr="$2"; shift 2 ;;
            -*) shift ;;
            *)  _url="$1"; shift ;;
        esac
    done
    _slug="$(printf '%s' "${_url}" | sed 's/[^A-Za-z0-9]/_/g')"
    [ -f "${STUB_FIXTURES}/${_slug}.body" ] || return 7
    if [ -n "${_hdr}" ]; then : > "${_hdr}"; fi
    if [ -n "${_out}" ]; then cat "${STUB_FIXTURES}/${_slug}.body" > "${_out}"
    else cat "${STUB_FIXTURES}/${_slug}.body"; fi
}
. "${STUB_BLOCKS}/resolver.sh"
. "${STUB_BLOCKS}/floor.sh"
. "${STUB_BLOCKS}/resolve.sh"
printf 'RESOLVED=%s\n' "${TAG}"
RUNNER

API_URL="https://api.github.com/repos/burrowee-git/release/releases?per_page=100"
mkdir -p "$W/fx"
printf '%s' '[{"tag_name":"gateway/v0.3.0.2026.09.01.aaaaaaaa"},{"tag_name":"gateway/v0.2.0.2026.08.08.79a5cfd7"},{"tag_name":"gateway/v0.2.0.2026.08.17.4e43c2ed"}]' \
    > "$W/fx/$(printf '%s' "$API_URL" | sed 's/[^A-Za-z0-9]/_/g').body"

resolve() {
    # resolve <floor-argument> -> prints the driver's output; exits non-zero
    # exactly where the shipped bootstrap would abort.
    rm -rf "$W/run-tmp"
    mkdir -p "$W/run-tmp"
    STUB_BLOCKS="$W" STUB_FIXTURES="$W/fx" STUB_MIN="0.2.0" STUB_ARG="$1" TMP="$W/run-tmp" \
        sh "$W/resolve-run.sh" 2>&1
}

resolved_tag() { printf '%s\n' "$1" | sed -n 's/^RESOLVED=//p'; }

got="$(resolve "")" || die "resolution with no argument failed:\n$got"
[ "$(resolved_tag "$got")" = "gateway/v0.3.0.2026.09.01.aaaaaaaa" ] \
    || die "with no argument the resolver answered '$(resolved_tag "$got")', want the newest release gateway/v0.3.0.2026.09.01.aaaaaaaa"
pass "no argument: the newest release wins, as install.sh has always done"

got="$(resolve "0.2.0")" || die "resolution with a floor named failed:\n$got"
[ "$(resolved_tag "$got")" = "gateway/v0.3.0.2026.09.01.aaaaaaaa" ] \
    || die "floor 0.2.0 changed the resolution to '$(resolved_tag "$got")' — the argument is the migration FLOOR and must NOT filter which release resolves (want gateway/v0.3.0.2026.09.01.aaaaaaaa)"
pass "a floor argument does not filter the resolution — 0.3.0's tag still wins"

printf '\n\342\234\223 UPGRADE-BOOTSTRAP OK (shells:%s)\n' "$SHELLS"
