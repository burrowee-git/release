#!/bin/sh
# tools/install-waits-for-daemon.test.sh — proves the shipped edge + gateway
# installers end by waiting for the NEW daemon to report itself, and then always
# run the component's doctor.
#
#     sh tools/install-waits-for-daemon.test.sh          # this shell
#     dash tools/install-waits-for-daemon.test.sh        # and this one, always
#
# THE ONE TEST THAT MATTERS, and why the others are not enough:
#
#   The requested predicate was "<config tree>/version == $BURROWEE_VERSION".
#   The only version file in a component's config tree is installed-version, and
#   THE INSTALLER WRITES IT ITSELF — so that comparison is the installer's own
#   write against the installer's own variable. It matches instantly, always,
#   including on a host where the daemon never started. A suite that only
#   exercised the MATCHING case would pass against exactly that bug.
#
#   So the case this file exists for is `old_version_times_out` below: with a
#   running.json holding an OLD version, the wait must time out. Against the
#   circular predicate it would have matched at once, and the test would fail.
#
# THE OTHER SILENT FAILURE — the path. The three daemons write running.json into
# three different homes, and edge's is the DATA tree, not the config tree. A
# wrong path never errors; the wait just always times out, so it adds the whole
# ceiling to every install and teaches operators to ignore the warning. Both
# path-agreement checks below therefore derive BOTH sides from source: the
# daemon's write target from the component repo, the installer's from the
# installer. Neither is restated here as a literal.
#
# SCOPE IS THE RELEASE REPO's two installers. relay ships its own install.sh from
# the relay repo and carries the equivalent cases in its own install_test.sh.

set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
EDGE="$HERE/inner/edge/install.sh"
GW="$HERE/inner/gateway/install.sh"

FAIL=0
SECTION_FAIL=0
note() { echo "FAIL: $1"; FAIL=1; }
ok() { echo "  ok: $1"; }
# section / ok_clean — a section's summary line prints only when that section
# raised nothing, so a green summary can never sit under its own FAIL.
section() { SECTION_FAIL="$FAIL"; }
ok_clean() { if [ "$SECTION_FAIL" = "$FAIL" ]; then ok "$1"; fi; }

[ -f "$EDGE" ] || { echo "FAIL: $EDGE not found"; exit 1; }
[ -f "$GW" ] || { echo "FAIL: $GW not found"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# extract_tunables <file> — the shared WAIT_* / SERVE_UNIT_STARTED block.
extract_tunables() {
    awk '
        /^# The post-start daemon wait/ { on = 1 }
        on { print }
        on && /^SERVE_UNIT_STARTED=0$/ { exit }
    ' "$1"
}

# extract_helpers <file> — the two shared helper functions, from the first line
# of binary_version_stamp's header through the close of wait_for_running_version.
extract_helpers() {
    awk '
        /^# binary_version_stamp <binary>/ { on = 1 }
        on { print }
        on && /^}$/ { n++; if (n == 2) exit }
    ' "$1"
}

# ── 1. the predicate is running.json, and never the installer's own marker ────
section
for f in "$EDGE" "$GW"; do
    # CODE only. The helper's own header explains at length why the
    # installed-version marker is unusable here, so a check that read the
    # comments would fire on the documentation of the rule it is enforcing.
    helpers="$(extract_helpers "$f" | grep -v '^[[:space:]]*#')"
    case "$helpers" in
        *'"$_dir/running.json"'*) ;;
        *) note "$(basename "$(dirname "$f")"): the wait does not read running.json" ;;
    esac
    case "$helpers" in
        *installed-version*)
            note "$(basename "$(dirname "$f")"): the wait reads an installed-version marker — the installer writes that file itself, so the predicate is circular" ;;
        *) ;;
    esac
done
ok_clean "the predicate is running.json in both installers"

# ── 2. the helpers are byte-identical across the two installers ──────────────
# House idiom for shared install-time logic (there is no shared lib): a
# duplicated block plus a drift pin. This is the pin for this block.
extract_helpers "$EDGE" > "$WORK/helpers.edge"
extract_helpers "$GW" > "$WORK/helpers.gateway"
[ -s "$WORK/helpers.edge" ] || note "no helper block found in inner/edge/install.sh"
[ -s "$WORK/helpers.gateway" ] || note "no helper block found in inner/gateway/install.sh"
if cmp -s "$WORK/helpers.edge" "$WORK/helpers.gateway"; then
    ok "wait_for_running_version + binary_version_stamp are byte-identical"
else
    note "the shared wait helpers have drifted between edge and gateway"
fi
# The tunables are part of the same shared block — a ceiling that differs by
# component is drift too, and it is the easy one to introduce by hand.
extract_tunables "$EDGE" > "$WORK/tunables.edge"
extract_tunables "$GW" > "$WORK/tunables.gateway"
[ -s "$WORK/tunables.edge" ] || note "no WAIT_*/SERVE_UNIT_STARTED block in inner/edge/install.sh"
[ -s "$WORK/tunables.gateway" ] || note "no WAIT_*/SERVE_UNIT_STARTED block in inner/gateway/install.sh"
if cmp -s "$WORK/tunables.edge" "$WORK/tunables.gateway"; then
    ok "the WAIT_INTERVAL / WAIT_CEILING / SERVE_UNIT_STARTED block is byte-identical"
else
    note "the wait tunables have drifted between edge and gateway"
fi
# The published values, stated once so a silent retune is visible.
for f in "$EDGE" "$GW"; do
    grep -q '^WAIT_INTERVAL="\${WAIT_INTERVAL:-2}"$' "$f" \
        || note "$(basename "$(dirname "$f")"): the poll interval is not 2s"
    grep -q '^WAIT_CEILING="\${WAIT_CEILING:-60}"$' "$f" \
        || note "$(basename "$(dirname "$f")"): the ceiling is not 60s"
done

# ── 3. behaviour, executed against the REAL helper ───────────────────────────
# Sourced from the shipped installer through its source-only seam, so what runs
# here is the function that ships — not a re-implementation that can agree with
# a broken original.
mkdir -p "$WORK/home" "$WORK/bin" "$WORK/data"

# run_wait <dir> <want> <ceiling> <interval> — echoes "<exit> <elapsed-seconds>"
# and writes the combined output to $WORK/out.
run_wait() {
    _t0="$(date +%s)"
    _rc=0
    (
        export HOME="$WORK/home"
        export SYS_BIN_DIR="$WORK/bin"
        export SYS_CONFIG_ROOT="$WORK/etc"
        export SYS_DATA_ROOT="$WORK/var"
        export WAIT_CEILING="$3"
        export WAIT_INTERVAL="$4"
        BURROWEE_INSTALLER_SOURCE_ONLY=1 . "$EDGE"
        wait_for_running_version "$1" "$2"
    ) > "$WORK/out" 2>&1 || _rc=$?
    echo "$_rc $(( $(date +%s) - _t0 ))"
}

write_running() { # <dir> <version>
    mkdir -p "$1"
    printf '{"version":"%s","pid":4242,"started_at":1756000000}' "$2" > "$1/running.json"
}

# 3a. THE NON-CIRCULAR CASE. running.json holds the OLD version: the wait must
#     spend its ceiling and time out. A predicate comparing the installer's own
#     installed-version marker to the installer's own variable would match here
#     instantly, and this assertion is what refuses it.
write_running "$WORK/data" "v0.2.8.2026.08.24.deadbeef"
set -- $(run_wait "$WORK/data" "v0.2.9.2026.08.25.cafebabe" 4 1)
if [ "$1" = 0 ]; then
    note "old_version_times_out: the wait MATCHED a running.json holding an older version"
elif [ "$2" -lt 3 ]; then
    note "old_version_times_out: returned after ${2}s — it did not honour the ceiling"
else
    grep -q "did not report version v0.2.9.2026.08.25.cafebabe" "$WORK/out" \
        || note "old_version_times_out: no warning naming the version it wanted"
    ok "an OLD running.json version times out instead of matching (${2}s)"
fi

# 3b. the matching case returns at once — a ceiling, not a sleep.
write_running "$WORK/data" "v0.2.9.2026.08.25.cafebabe"
set -- $(run_wait "$WORK/data" "v0.2.9.2026.08.25.cafebabe" 30 2)
if [ "$1" != 0 ]; then
    note "match_returns_0: the wait did not match a running.json holding the wanted version"
elif [ "$2" -gt 1 ]; then
    note "match_returns_0: took ${2}s for a version already present — it is sleeping, not polling"
else
    grep -q "daemon is serving v0.2.9.2026.08.25.cafebabe" "$WORK/out" \
        || note "match_returns_0: no line reporting the serving version"
    ok "a matching running.json returns immediately (${2}s)"
fi

# 3c. absent running.json — the daemon never wrote one — times out, never matches.
rm -rf "$WORK/empty"; mkdir -p "$WORK/empty"
set -- $(run_wait "$WORK/empty" "v0.2.9.2026.08.25.cafebabe" 2 1)
[ "$1" = 0 ] && note "absent_running_json: the wait matched with no running.json at all"
[ "$1" = 0 ] || ok "an absent running.json times out (${2}s)"

# 3d. EARLY EXIT. The version appears on the second poll: the wait must return
#     then, not run out the ceiling.
rm -rf "$WORK/late"; mkdir -p "$WORK/late"
( sleep 2; write_running "$WORK/late" "v0.2.9.2026.08.25.cafebabe" ) &
_writer=$!
set -- $(run_wait "$WORK/late" "v0.2.9.2026.08.25.cafebabe" 30 1)
wait "$_writer" 2>/dev/null || true
if [ "$1" != 0 ]; then
    note "early_exit: the wait never saw a running.json written during the poll loop"
elif [ "$2" -gt 8 ]; then
    note "early_exit: returned after ${2}s with a 30s ceiling — it is not returning on the match"
else
    ok "the wait returns on the poll that matches, not at the ceiling (${2}s)"
fi

# 3e. progress. A slow start must not look like a hang: every poll prints a line.
grep -q "waiting for the daemon to report" "$WORK/out" \
    || note "no progress line — a slow start is indistinguishable from a hang"

# ── 4. binary_version_stamp reads the BINARY's own stamp ─────────────────────
section
# It is what the wait compares against, because it is the same variable the
# daemon writes into running.json. Two ways it can go wrong, both executed.
cat > "$WORK/bin/stub" <<'STUB'
#!/bin/sh
if [ -n "${BURROWEE_DISPATCHER_VERSION:-}" ]; then
    echo "dispatcher v9.9.9.2026.01.01.deadbeef"
fi
echo "burrowee-edge v0.2.9.2026.08.25.cafebabe  (installed binary)"
echo "running daemon:  v0.1.0.2026.01.01.00000000  ⚠ drift"
STUB
chmod 0755 "$WORK/bin/stub"
stamp_of() {
    (
        export HOME="$WORK/home" SYS_BIN_DIR="$WORK/bin"
        export SYS_CONFIG_ROOT="$WORK/etc" SYS_DATA_ROOT="$WORK/var"
        BURROWEE_INSTALLER_SOURCE_ONLY=1 . "$EDGE"
        binary_version_stamp "$WORK/bin/stub"
    )
}
got="$(stamp_of)"
[ "$got" = "v0.2.9.2026.08.25.cafebabe" ] \
    || note "binary_version_stamp returned '$got', not the installed binary's own stamp"
got="$(BURROWEE_DISPATCHER_VERSION=v9.9.9.2026.01.01.deadbeef stamp_of)"
[ "$got" = "v0.2.9.2026.08.25.cafebabe" ] \
    || note "binary_version_stamp returned '$got' with a dispatcher version in the environment"
got="$(
    (
        export HOME="$WORK/home" SYS_BIN_DIR="$WORK/bin"
        export SYS_CONFIG_ROOT="$WORK/etc" SYS_DATA_ROOT="$WORK/var"
        BURROWEE_INSTALLER_SOURCE_ONLY=1 . "$EDGE"
        binary_version_stamp "$WORK/bin/does-not-exist"
    )
)"
[ -z "$got" ] || note "binary_version_stamp invented '$got' for a binary that does not exist"
ok_clean "binary_version_stamp reads the binary's own stamp, dispatcher row and all"

# ── 5. path agreement, per component, both sides from source ─────────────────
# The daemon's write target comes from the component repo; the installer's from
# the installer. Nothing here is a literal path.
BRAND=""
_p="$HERE"
while [ "$_p" != "/" ]; do
    if [ -f "$_p/edge/code/edge/internal/edgeroot/roots.go" ] \
        && [ -f "$_p/gateway/code/gateway/internal/gateway/home.go" ]; then
        BRAND="$_p"
        break
    fi
    _p="$(dirname "$_p")"
done

go_const() { # <file> <name> — the string literal assigned to a Go const/var
    grep -E "^[[:space:]]*(const[[:space:]]+|var[[:space:]]+)?$2[[:space:]]*=" "$1" \
        | head -n 1 \
        | sed -n 's/.*"\([^"]*\)".*/\1/p'
}
sh_default() { # <file> <VAR> — the :- default of VAR="${…:-default}"
    sed -n "s/^$2=\"\${[A-Z_]*:-\([^}\"]*\)}\".*/\1/p" "$1" | head -n 1
}

if [ -z "$BRAND" ]; then
    note "component sources not found beside the release repo — the path-agreement checks did NOT run"
else
    # edge — cmd/burrowee-edge/config.go writes through edgeData(), which is
    # edgeroot.DataDirFor(edgeHome()): the DATA tree, not the config tree.
    ecfg="$BRAND/edge/code/edge/cmd/burrowee-edge/config.go"
    eroots="$BRAND/edge/code/edge/internal/edgeroot/roots.go"
    grep -q 'WriteRunning(edgeData(), version)' "$ecfg" \
        || note "edge: recordRunningVersion no longer writes through edgeData() — re-derive the installer's path"
    edge_daemon="$(go_const "$eroots" systemDataRoot)/$(go_const "$eroots" Name)"
    edge_installer="$(
        (
            export HOME="$WORK/home"
            unset SYS_CONFIG_ROOT SYS_DATA_ROOT SYS_BIN_DIR
            BURROWEE_INSTALLER_SOURCE_ONLY=1 . "$EDGE"
            printf '%s' "$COMP_DATA"
        )
    )"
    if [ -n "$edge_daemon" ] && [ "$edge_daemon" = "$edge_installer" ]; then
        ok "edge: installer \$COMP_DATA == the daemon's running.json tree ($edge_daemon)"
    else
        note "edge: installer writes the wait at '$edge_installer', the daemon writes running.json to '$edge_daemon'"
    fi

    # gateway — cmd/burrowee-gateway/main.go writes to cfg.paths.Home, and
    # GatewayPaths sets Home from dataDir (internal/gateway/home.go).
    gmain="$BRAND/gateway/code/gateway/cmd/burrowee-gateway/main.go"
    ghome="$BRAND/gateway/code/gateway/internal/gateway/home.go"
    grep -q 'WriteRunning(cfg.paths.Home, version)' "$gmain" \
        || note "gateway: main.go no longer writes running.json to cfg.paths.Home — re-derive the installer's path"
    grep -q 'Home:  *dataDir,' "$ghome" \
        || note "gateway: GwPaths.Home is no longer the data dir — the installer's \$SYS_DATA_DIR may be the wrong tree"
    gw_daemon="$(go_const "$ghome" systemDataDir)"
    gw_installer="$(sh_default "$GW" SYS_DATA_DIR)"
    if [ -n "$gw_daemon" ] && [ "$gw_daemon" = "$gw_installer" ]; then
        ok "gateway: installer \$SYS_DATA_DIR == the daemon's running.json tree ($gw_daemon)"
    else
        note "gateway: installer waits on '$gw_installer', the daemon writes running.json to '$gw_daemon'"
    fi
fi

# Each installer must wait on ITS OWN data variable — the config tree is the
# wrong answer for all three components, and it is the tempting one.
grep -q 'wait_for_running_version "\$COMP_DATA"' "$EDGE" \
    || note "edge: the wait is not called with \$COMP_DATA"
grep -q 'wait_for_running_version "\$COMP_HOME"' "$EDGE" \
    && note "edge: the wait is called with the CONFIG tree — the daemon writes running.json to the DATA tree"
grep -q 'wait_for_running_version "\$SYS_DATA_DIR"' "$GW" \
    || note "gateway: the wait is not called with \$SYS_DATA_DIR"
grep -q 'wait_for_running_version "\$SYS_CONFIG_DIR"' "$GW" \
    && note "gateway: the wait is called with the CONFIG tree — the daemon writes running.json to the DATA tree"

# ── 6. the gate: the wait is armed only by a VERIFIED serve-unit start ───────
section
for f in "$EDGE" "$GW"; do
    comp="$(basename "$(dirname "$f")")"
    grep -q '^SERVE_UNIT_STARTED=0' "$f" \
        || note "$comp: SERVE_UNIT_STARTED is not initialised to 0"
    grep -q 'if \[ "\$SERVE_UNIT_STARTED" = 1 \]; then' "$f" \
        || note "$comp: the wait is not gated on SERVE_UNIT_STARTED"
    # It is set exactly twice — the darwin serve start and the linux serve start
    # — and never beside an updater start.
    n="$(grep -c '^ *SERVE_UNIT_STARTED=1$' "$f")"
    [ "$n" = 2 ] || note "$comp: SERVE_UNIT_STARTED=1 appears $n times, expected 2 (one per platform's SERVE unit)"
    grep -n 'SERVE_UNIT_STARTED=1' "$f" | while IFS=: read -r ln _; do
        prev="$(sed -n "$((ln - 1))p;$((ln - 2))p;$((ln - 3))p" "$f")"
        case "$prev" in
            *UPDATER*) echo "FAIL: $comp: SERVE_UNIT_STARTED=1 follows an UPDATER start — a live updater says nothing about the serving daemon" ;;
            *) ;;
        esac
    done
done
grep -q 'BURROWEE_NO_RESTART' "$GW" || note "gateway: BURROWEE_NO_RESTART is no longer honoured"
ok_clean "the wait is armed only by a verified SERVE-unit start"

# ── 7. the doctor tail runs unconditionally, and cannot change the verdict ───
section
# Column 0: outside the SERVE_UNIT_STARTED conditional, so the match path, the
# timeout path and the skipped path all reach it.
grep -q '^"\$SYS_BIN_DIR/burrowee-edge-cli" doctor < /dev/null || true$' "$EDGE" \
    || note "edge: no unconditional, guarded, non-interactive doctor tail"
grep -q '^"\$BIN_DIR/burrowee-gateway-cli" doctor < /dev/null || true$' "$GW" \
    || note "gateway: no unconditional, guarded, non-interactive doctor tail"
for f in "$EDGE" "$GW"; do
    comp="$(basename "$(dirname "$f")")"
    grep -qE '(burrowee-edge-cli|burrowee-gateway-cli)" doctor.*--fix' "$f" \
        && note "$comp: the doctor tail passes --fix — the install's last act must be a report, not a remediation"
    tail -n 1 "$f" | grep -q 'doctor < /dev/null || true' \
        || note "$comp: the doctor tail is not the last thing the script does"
done
ok_clean "doctor runs last, unconditionally, guarded, with a non-terminal stdin"

# ── 8. both scripts still parse, on both shells ──────────────────────────────
for f in "$EDGE" "$GW"; do
    sh -n "$f" || note "$f does not parse under sh"
    command -v dash >/dev/null 2>&1 && { dash -n "$f" || note "$f does not parse under dash"; }
done

[ "$FAIL" = 0 ] || { echo "install-waits-for-daemon: FAILED"; exit 1; }
echo "ALL OK"
