#!/usr/bin/env bash
# test-elevate.sh — offline checks for the outer bootstrap's elevation decision.
#
# THE STORY THIS PINS: a root-only component (gateway, edge) installs to
# /usr/local/bin, root-owned. Today the outer bootstrap hands the verified
# inner installer straight to plain `sh` — so on an ordinary non-root run the
# whole verify chain (download, minisign, checksum, tag binding) succeeds and
# THEN the inner installer's own root gate dead-ends it, after all that work.
# The fix is elevation: the outer bootstrap itself must reach for `sudo` around
# the inner installer for gateway/edge, never for the per-user components
# (cli, agent), never when already root, and it must do so without silently
# dropping or flattening the env vars the inner installer depends on. This
# suite asserts the DECISION, not the mechanism: it renders the real bootstrap
# template against a fabricated local release and a `sudo` STUB that records
# argv instead of elevating, so every assertion below observes what the
# rendered script actually chose to run.
#
# Prints `ELEVATE-TEST OK` on success. Fails TODAY at assertion (1): the
# bootstrap does not elevate yet, so the stub's log is empty.
#
# Harness shape (work dir, restore-on-exit, say/die) copied from
# tools/test-preflight.sh. Render-into-a-scratch-root + fabricate-sign-serve a
# local release copied from tools/test-upgrade-bootstrap.sh, which already
# proves that pattern works offline against this same template family. NEITHER
# is modified by this file.
#
# Needs: minisign, zip, unzip, curl, python3, and shasum or sha256sum.
#
# POSIX-adjacent but run under bash 3.2 (macOS /bin/bash, and what `sh` is on
# this box) — no mapfile, no associative arrays, no ${var^^}.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PORT="${ELEVATE_TEST_PORT:-8842}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n\342\234\227 ELEVATE-TEST FAILED: %s\n' "$*" >&2; exit 1; }
pass() { printf '  OK: %s\n' "$*"; }

for t in minisign zip unzip curl python3; do
    command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"
done
if command -v shasum >/dev/null 2>&1; then SUMS="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then SUMS="sha256sum"
else die "neither shasum nor sha256sum found"; fi

case "$(uname -s)" in Darwin) OS=darwin ;; Linux) OS=linux ;; *) die "unsupported OS $(uname -s)" ;; esac
case "$(uname -m)" in arm64 | aarch64) ARCH=arm64 ;; x86_64 | amd64) ARCH=amd64 ;; *) die "unsupported arch $(uname -m)" ;; esac

# ---- work dir + cleanup ------------------------------------------------------
# This suite never touches the working tree: it copies the templates and
# gen-bootstraps.sh into $WORK/repo and renders THERE (same reasoning as
# test-upgrade-bootstrap.sh). So cleanup is just "stop the fake server and
# remove the scratch dir" — no bytes to restore. INT and TERM alongside EXIT so
# a killed run doesn't leave a python3 listening on $PORT for the next one.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-elevate-XXXXXX")"
export WORK
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

SUDO_LOG="$WORK/sudo.log"
export SUDO_LOG
: > "$SUDO_LOG"

mkdir -p "$WORK/bin" "$WORK/sudobin" "$WORK/home" "$WORK/kitsrc" "$WORK/serve"

# ---- sudo stub: records argv, runs nothing privileged -----------------------
# The stub is how every assertion below observes the elevation decision without
# a real sudo. It appends its full argv to $SUDO_LOG. NORMALLY it then EXECUTES
# the rest -- an elevation test that stopped at the stub would prove the
# bootstrap called sudo and nothing about whether the install then worked -- but
# under SUDO_FAILS=1 (assertion 6's "no cached creds, no tty" scenario) it exits
# non-zero instead, the way a real sudo does when it cannot prompt and has
# nothing cached.
#
# Real sudo additionally treats leading NAME=value words as environment
# assignments for the command it execs, not as the command itself (this is how
# `sudo PREFIX=/usr/local BURROWEE_VERSION=… sh ./install.sh` is expected to
# behave once Task 2 lands it). A stub that skipped this and did a bare
# `exec "$@"` would try to exec the literal string "PREFIX=/usr/local" as a
# program and fail -- so the stub parses and exports that prefix itself before
# handing off to the real command, same as sudo/env would.
#
# Real sudo ALSO accepts its own flags (`-n`, `-v`, ...) ahead of the command --
# resolve_elevate's cached-credentials probe is `sudo -n true`. Without a flag
# skip here, `-n` falls through to the exec fallback below as the literal
# argv[0]: `exec "$@"` on bash 3.2 (/bin/sh on this box) parses a bare `-n` as
# an (invalid) option to the `exec` BUILTIN itself, not as a program name, and
# errors out -- a stub artifact, not anything real sudo does. So any leading
# `-`-prefixed token is skipped generically, the same as a NAME=value one,
# before the exec fallback.
make_sudo_stub() {
    cat > "$WORK/sudobin/sudo" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SUDO_LOG"
if [ -n "${SUDO_FAILS:-}" ]; then
    echo "sudo: a password is required" >&2
    exit 1
fi
while [ $# -gt 0 ]; do
    case "$1" in
        -*)             shift ;;
        [A-Za-z_]*=*) eval "export $1"; shift ;;
        *) break ;;
    esac
done
exec "$@"
STUB
    chmod +x "$WORK/sudobin/sudo"
}

# ---- id stub: only overrides `id -u` under an explicit FAKE_UID -------------
# We fake the uid this way, on the same PATH as the sudo stub, rather than
# adding a FAKE_UID seam to the shipped template -- a production template must
# not grow an env knob that exists only for tests. Every other invocation (and
# every invocation when FAKE_UID is unset) falls straight through to the real
# `id`, resolved once now, before this stub is on PATH, so it can never resolve
# to itself.
make_id_stub() {
    _real_id="$(command -v id)" || die "test host is missing id"
    cat > "$WORK/bin/id" <<STUB
#!/bin/sh
if [ "\${1:-}" = "-u" ] && [ -n "\${FAKE_UID:-}" ]; then
    printf '%s\n' "\$FAKE_UID"
    exit 0
fi
exec "$_real_id" "\$@"
STUB
    chmod +x "$WORK/bin/id"
}

make_sudo_stub
make_id_stub

# nosudo_path — a curated PATH dir that mirrors the CURRENT $PATH's resolution
# order (first dir wins, like real PATH search) but symlinks nothing named
# `sudo`. Used only for the NO_SUDO=1 scenario (assertion 7): the real system
# does have a real /usr/bin/sudo, and dropping whole directories to hide it
# would also drop curl/unzip/shasum/sed/uname/env from the very same
# directories. Symlinking file-by-file keeps everything else intact.
NOSUDO_DIR="$WORK/nosudobin"
nosudo_path() {
    if [ ! -d "$NOSUDO_DIR" ]; then
        mkdir -p "$NOSUDO_DIR"
        _old_ifs="$IFS"
        IFS=:
        for _d in $PATH; do
            [ -d "$_d" ] || continue
            for _f in "$_d"/*; do
                [ -f "$_f" ] && [ -x "$_f" ] || continue
                _b="${_f##*/}"
                [ "$_b" = "sudo" ] && continue
                [ -e "$NOSUDO_DIR/$_b" ] && continue
                ln -s "$_f" "$NOSUDO_DIR/$_b" 2>/dev/null || true
            done
        done
        IFS="$_old_ifs"
    fi
    printf '%s' "$NOSUDO_DIR"
}

# ---- render every public bootstrap into a SCRATCH root ----------------------
# Same reasoning as test-upgrade-bootstrap.sh: copy the templates + generator
# rather than run gen-bootstraps.sh in place, so a failed run leaves the
# checked-in tree untouched and there is nothing to restore.
say "RENDER: gen-bootstraps.sh into a scratch root (the worktree is not touched)"
mkdir -p "$WORK/repo/tools"
for f in bootstrap.template.sh relay-bootstrap.template.sh preflight.template.sh gen-bootstraps.sh; do
    cp "$REPO_ROOT/tools/$f" "$WORK/repo/tools/$f"
done
minisign -G -W -p "$WORK/test.pub" -s "$WORK/test.key" >/dev/null 2>&1 \
    || die "could not generate an ephemeral minisign keypair"
BURROWEE_PUBKEY_FILE="$WORK/test.pub" BURROWEE_MIN_VERSION="0.1.0" \
    sh "$WORK/repo/tools/gen-bootstraps.sh" >/dev/null \
    || die "gen-bootstraps.sh failed in the scratch root"
for c in cli gateway edge agent; do
    [ -f "$WORK/repo/$c/install.sh" ] || die "gen-bootstraps.sh rendered no $c/install.sh"
    [ -f "$WORK/repo/$c/upgrade.sh" ] || die "gen-bootstraps.sh rendered no $c/upgrade.sh"
done
pass "rendered cli/gateway/edge/agent install.sh + upgrade.sh under $WORK/repo"

# ---- fabricate + sign a one-file-fixture release per component --------------
# ONE kit shape covers every assertion in this suite: an inner install.sh that
# marks its own component as "placed" (so assertion 6 can prove a refusal
# placed nothing) and logs the env it saw (so assertions 4/5 can prove what did
# and did not cross the sudo boundary), plus a migrations/ ladder fixture
# complete enough to pass the pre-invocation kit checks so assertion 8 can
# reach the actual forcing entry.
fabricate_kit() {
    _comp="$1"
    _src="$WORK/kitsrc/$_comp"
    mkdir -p "$_src/migrations"
    cat > "$_src/install.sh" <<INNER
#!/bin/sh
mkdir -p "\$WORK/dest"
: > "\$WORK/dest/burrowee-$_comp"
printf 'install comp=$_comp version=%s prefix=%s\n' "\${BURROWEE_VERSION:-}" "\${PREFIX:-<unset>}" >> "\$WORK/install.log"
exit 0
INNER
    cat > "$_src/migrations/upgrade.sh" <<INNER
#!/bin/sh
printf 'migrate comp=$_comp argc=%s arg1=%s\n' "\$#" "\${1:-}" >> "\$WORK/install.log"
exit 0
INNER
    cat > "$_src/migrations/run.sh" <<'RUNNER'
#!/bin/sh
exit 0
RUNNER
    cat > "$_src/migrations/ledger" <<'LEDGER'
0.1.0 v0_0_to_v0_1.sh
0.2.0 v0_1_to_v0_2.sh
LEDGER
    chmod +x "$_src/install.sh" "$_src/migrations/upgrade.sh" "$_src/migrations/run.sh"

    _stamp="v0.1.0.2026.01.01.elevatetest"
    _tag="$_comp/$_stamp"
    printf '%s' "$_tag" > "$WORK/tag.$_comp"

    _zip="burrowee-${_comp}-${OS}-${ARCH}.zip"
    mkdir -p "$WORK/serve/$_comp"
    ( cd "$_src" && zip -qr "$WORK/serve/$_comp/$_zip" install.sh migrations ) \
        || die "zip failed for $_comp fixture kit"
    ( cd "$WORK/serve/$_comp" && $SUMS "$_zip" > SHA256SUMS.txt ) \
        || die "checksum failed for $_comp fixture kit"
    ( cd "$WORK/serve/$_comp" \
        && minisign -S -m SHA256SUMS.txt -s "$WORK/test.key" \
            -c "burrowee test release" -t "burrowee $_comp $_stamp" >/dev/null 2>&1 ) \
        || die "minisign signing failed for $_comp fixture kit"
    unzip -Z1 "$WORK/serve/$_comp/$_zip" | grep -qx 'migrations/upgrade.sh' \
        || die "the fabricated $_comp kit does not carry migrations/upgrade.sh — the fixture proves nothing"
}

say "FABRICATE: one signed fixture release per component"
for c in cli gateway edge agent; do fabricate_kit "$c"; done
pass "signed fixture kits under $WORK/serve/{cli,gateway,edge,agent}"

# ---- serve --------------------------------------------------------------
say "SERVE: 127.0.0.1:$PORT"
( cd "$WORK/serve" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
SERVER_PID=$!
i=0
until curl -fsS "http://127.0.0.1:$PORT/edge/burrowee-edge-${OS}-${ARCH}.zip" -o /dev/null 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || die "http server did not come up on $PORT"
    sleep 0.1
done
BASE_URL="http://127.0.0.1:$PORT"
pass "server up"

# ---- run_bootstrap <comp> [mode] [floor] -------------------------------------
# Runs the ALREADY-RENDERED <comp>/<mode>.sh (mode defaults to install) against
# the already-served fixture kit for <comp>, with the sudo/id stubs on PATH.
# Output (stdout+stderr) and exit code are whatever the caller's own context
# captures -- a bare call lets both flow to this script's own, matching how
# assertions (1)(2)(3)(4)(5)(8) use it; a caller can equally wrap the whole
# call in `out="$(... run_bootstrap … 2>&1)"` to capture both, matching (6)(7).
#
# NO_SUDO=1, SUDO_FAILS=1, FAKE_UID=<n> are read from the environment this
# function inherits from ITS caller (a `VAR=val run_bootstrap …` prefix exports
# VAR for exactly this call, plain bash semantics) -- none of them are ever
# passed into the rendered bootstrap's own env; they only steer which PATH and
# which sudo-stub behavior this harness sets up before running it.
run_bootstrap() {
    _comp="$1"
    _mode="${2:-install}"
    _floor="${3:-}"

    _script="$WORK/repo/$_comp/$_mode.sh"
    [ -f "$_script" ] || die "run_bootstrap: no rendered $_comp/$_mode.sh"

    case "$_comp" in
        cli)     _pinvar=BURROWEE_CLI_VERSION ;;
        gateway) _pinvar=BURROWEE_GATEWAY_VERSION ;;
        edge)    _pinvar=BURROWEE_EDGE_VERSION ;;
        agent)   _pinvar=BURROWEE_AGENT_VERSION ;;
        *) die "run_bootstrap: component '$_comp' is not wired into this suite (only cli/gateway/edge/agent — no assertion here exercises relay)" ;;
    esac
    _tag="$(cat "$WORK/tag.$_comp")"

    if [ -n "${NO_SUDO:-}" ]; then
        _path="$WORK/bin:$(nosudo_path)"
    else
        _path="$WORK/sudobin:$WORK/bin:$PATH"
    fi

    if [ -n "$_floor" ]; then
        env "$_pinvar=$_tag" \
            BURROWEE_SKIP_PREFLIGHT=1 BURROWEE_GH_PROXY= \
            BURROWEE_DL_BASE="$BASE_URL/$_comp" \
            HOME="$WORK/home" PATH="$_path" \
            sh "$_script" "$_floor" < /dev/null
    else
        env "$_pinvar=$_tag" \
            BURROWEE_SKIP_PREFLIGHT=1 BURROWEE_GH_PROXY= \
            BURROWEE_DL_BASE="$BASE_URL/$_comp" \
            HOME="$WORK/home" PATH="$_path" \
            sh "$_script" < /dev/null
    fi
}

# ============================================================================
# THE ASSERTIONS
# ============================================================================

# ---- (1) root-only comps elevate the inner handoff -------------------------
say "ASSERT (1): gateway/edge go through sudo for the inner installer"
for comp in gateway edge; do
    : > "$SUDO_LOG"
    run_bootstrap "$comp"
    grep -q 'sh ./install.sh' "$SUDO_LOG" \
        || die "($comp) inner installer did not go through sudo"
    pass "($comp) sudo saw: $(cat "$SUDO_LOG")"
done

# ---- (2) per-user comps do NOT elevate -------------------------------------
say "ASSERT (2): cli/agent never reach for sudo"
for comp in cli agent; do
    : > "$SUDO_LOG"
    run_bootstrap "$comp"
    [ ! -s "$SUDO_LOG" ] \
        || die "($comp) per-user install reached for sudo: $(cat "$SUDO_LOG")"
    pass "($comp) sudo log stayed empty"
done

# ---- (3) already root never calls sudo --------------------------------------
say "ASSERT (3): a root run never elevates"
: > "$SUDO_LOG"
FAKE_UID=0 run_bootstrap edge
[ ! -s "$SUDO_LOG" ] \
    || die "a root run still called sudo: $(cat "$SUDO_LOG")"
pass "root (FAKE_UID=0) edge install skipped sudo"

# ---- (4) env survives the sudo boundary -------------------------------------
# sudo scrubs the environment. PREFIX is the one that matters: the gateway and
# edge installers branch on [ -n "${PREFIX:-}" ] to decide whether an operator
# asked for a per-user install, so a DROPPED PREFIX reads as "operator set
# nothing" and a deliberate PREFIX=/usr/local silently stops being honoured.
say "ASSERT (4): PREFIX and BURROWEE_VERSION survive the sudo boundary"
: > "$SUDO_LOG"
PREFIX=/usr/local run_bootstrap edge
grep -q 'PREFIX=/usr/local' "$SUDO_LOG" \
    || die "PREFIX did not survive the sudo boundary: $(cat "$SUDO_LOG")"
grep -q 'BURROWEE_VERSION=' "$SUDO_LOG" \
    || die "BURROWEE_VERSION did not survive the sudo boundary"
pass "PREFIX and BURROWEE_VERSION both crossed the boundary"

# ---- (5) unset PREFIX arrives UNSET, not empty ------------------------------
# The empty-vs-unset distinction is load-bearing; passing an empty PREFIX would
# read as an operator who set one to nothing. Written as an explicit if/die,
# not `grep … && die`: under set -euo pipefail a FALSE grep (the passing case)
# makes that compound non-zero and kills the whole suite on the path that is
# supposed to succeed, so a bare `&&` form here could only ever fail the
# assertion — never actually prove anything on a passing run.
say "ASSERT (5): an unset PREFIX crosses the boundary unset, never as empty"
: > "$SUDO_LOG"
run_bootstrap edge
if grep -q 'PREFIX=' "$SUDO_LOG"; then
    die "an unset PREFIX was passed as empty across the boundary: $(cat "$SUDO_LOG")"
fi
pass "no PREFIX= token crossed the boundary when the operator set none"

# ---- (6) no tty + no cached creds -> refuse, place nothing ------------------
say "ASSERT (6): no tty and no cached sudo creds -> refuse, place nothing"
: > "$SUDO_LOG"
rm -rf "$WORK/dest"
out="$(NO_TTY=1 SUDO_FAILS=1 run_bootstrap edge 2>&1)" && die "expected refusal, got success:\n$out"
printf '%s' "$out" | grep -q 'sudo sh' \
    || die "refusal did not name the way through: $out"
[ ! -e "$WORK/dest/burrowee-edge" ] \
    || die "refused, but a binary was placed anyway"
pass "refused without a usable sudo, and placed nothing"

# ---- (7) sudo absent -> distinct refusal, place nothing --------------------
say "ASSERT (7): no sudo binary on PATH -> a distinct refusal"
: > "$SUDO_LOG"
rm -rf "$WORK/dest"
out="$(NO_SUDO=1 run_bootstrap edge 2>&1)" && die "expected refusal, got success:\n$out"
printf '%s' "$out" | grep -qi 'sudo is not installed' \
    || die "no-sudo refusal named a command the host does not have: $out"
[ ! -e "$WORK/dest/burrowee-edge" ] \
    || die "refused, but a binary was placed anyway"
pass "refused by name when sudo itself is missing, and placed nothing"

# ---- (8) upgrade mode elevates the ladder too -------------------------------
say "ASSERT (8): upgrade mode elevates the forced migration ladder too"
: > "$SUDO_LOG"
run_bootstrap edge upgrade 0.2.0
grep -q 'migrations/upgrade.sh' "$SUDO_LOG" \
    || die "the forced migration ladder did not go through sudo"
pass "the ladder's forcing entry also ran under sudo"

# ---- (9) both templates carry byte-identical elevation literals ------------
# Same invariant as the preflight's nginx_guide vs core's setup.NginxGuide: two
# copies of an operator-facing command that drift are worse than one copy that
# is wrong, because nobody can tell which is current.
#
# needs_root_comp() differs BY DESIGN between the two templates (the shared
# one switches on $COMP; relay is root-only unconditionally), so the range
# compared is bounded by explicit markers in both files -- BEGIN/END pinned
# elevation literals -- placed just after each file's own needs_root_comp()
# and around has_tty()/resolve_elevate()/ELEVATE=, not by a brace-counting sed
# range that would sweep needs_root_comp() in too.
say "ASSERT (9): the two templates' elevation literals are byte-identical"
extract_block() {
    sed -n '/^# ---- BEGIN pinned elevation literals/,/^# ---- END pinned elevation literals/p' "$1"
}
if ! diff <(extract_block tools/bootstrap.template.sh) \
          <(extract_block tools/relay-bootstrap.template.sh) > "$WORK/elev.diff"; then
    die "elevation blocks drifted between the two templates:
$(cat "$WORK/elev.diff")"
fi
extract_block tools/bootstrap.template.sh | grep -q '^has_tty() {$' \
    || die "extract_block found nothing -- the BEGIN/END markers are missing or misspelled"
pass "elevation literals identical between tools/bootstrap.template.sh and tools/relay-bootstrap.template.sh"

printf '\n\342\234\223 ELEVATE-TEST OK\n'
