#!/bin/sh
# _shared/migrations/adopt_updater_unit.sh — converge a legacy PER-USER updater
# agent onto the SYSTEM unit: a launchd LaunchDaemon on macOS, a systemd
# system-scope unit on Linux. Target version 0.2.0 (see the component's
# migrations/updater-ledger — this ladder's own ledger, walked by
# updater.update.sh, separate from the serve ladder's migrations/ledger).
#
# WHY THIS RUNG EXISTS AND THE SERVE LADDER CANNOT BE IT. A host still running
# the pre-0.2.0 per-user updater agent has no path off it:
#
#   * adopt_user_tree.sh (the serve ladder's own 0.2.0 rung) deliberately never
#     touches the updater — "update.sh runs UNDER burrowee-<comp>-updater, so
#     booting that out would kill the process running this script." Structural,
#     not an oversight.
#   * <comp>/updater.update.sh restarts whichever supervisor answers first —
#     legacy gui/…org.burrowee.<comp>-updater, then the system domain — which
#     perpetuates the legacy agent rather than converging it.
#
# So this rung runs ON the updater's OWN ladder, invoked from updater.update.sh,
# which is already permitted to bounce the updater's own service — the one
# track that is.
#
# IT IS BOOTING OUT THE SUPERVISOR OF THE PROCESS RUNNING IT — IN EITHER OF TWO
# DOMAINS. On the host this exists for, the process walking this ladder IS one
# of two legacy agents (see NAMING below for exactly which): a launchd job in
# the invoking user's gui/<uid> domain, unprivileged, OR a launchd job in the
# SYSTEM domain — a pre-rename system LaunchDaemon, which requires root like
# any other system-domain unit. So the two legacy bootouts below are NOT
# uniformly privileged: the gui-domain one runs as whichever identity is
# already running this script — never elevated, and never resolved through a
# second guess at "which user" the way adopt_user_tree.sh has to for a tree it
# did not just read itself out of — while the system-domain one elevates, same
# as every other system-domain mutation here (the new unit's own write/enable
# steps included). Both are still "individual steps elevate, not the whole
# script" — mirrors adopt_user_tree.sh — it is just that STEP 3 now has one
# elevated half and one unprivileged half instead of being uniformly one or
# the other.
#
# THE ORDER IS THE WHOLE SAFETY ARGUMENT AND MUST NOT BE REORDERED:
#
#     write the system unit → verify it loads → bootout BOTH legacy domains → receipt
#
# Reversing steps 1 and 3 would boot the only supervisor keeping this component
# updated — in WHICHEVER domain it currently lives — before a replacement is
# confirmed live: a host stuck between agents converges on nothing. This holds
# identically for both legacy domains; neither bootout may run before the new
# unit is loaded and verified. The receipt (step 4) is written by run.sh, not
# here, after this script exits 0; see EVERY STEP IS IDEMPOTENT below for why a
# run killed at ANY point among the first three steps — including between the
# two legacy domains' bootouts — still converges cleanly on re-run, with no
# receipt recorded for the partial attempt.
#
# EVERY STEP IS IDEMPOTENT.
#   1. write_system_unit    overwrites the unit file with the same content every
#                            time; never appends, never reads what was there.
#   2. enable_system_unit   bootstrap/enable/kickstart (launchd) or
#                            daemon-reload + enable --now (systemd) are each
#                            safe to repeat on an already-loaded unit.
#   3. bootout_legacy        `bootout`/`disable --now`, in EACH domain, on a
#                            target that is already gone is a normal, silent
#                            no-op (`|| true`) — true independently for the
#                            gui-domain call and the system-domain call, so
#                            the two may complete in either order relative to
#                            each other and a kill between them still leaves a
#                            re-run with exactly one thing left to do.
# A run killed after step 1 or 2 leaves BOTH legacy domains still up (neither
# has been touched yet) and the system unit already written/loading —
# re-running from the top repeats 1-2 harmlessly and reaches 3. A run killed
# DURING step 3 — including strictly between the gui-domain bootout completing
# and the system-domain one starting — leaves whichever domain's bootout had
# already completed gone and the other still up; re-running repeats the
# completed one (a no-op, per above) and finishes the interrupted one. A run
# killed after step 3 leaves both units in their FINAL state; run.sh recorded
# no receipt (the script had not exited yet), so a re-run repeats all three
# steps and finds nothing left to do — never a state with neither unit up, and
# never a state where one legacy domain is swept but the other was silently
# skipped.
#
# --applies ANSWERS "STILL NEEDED" WHENEVER IT CANNOT TELL, matching
# adopt_user_tree.sh: legacy_unit_present() below returns true (needs
# converging) unless it can positively confirm the legacy agent is gone. Two
# reasons the real run, invoked unconditionally once the ladder's version gate
# selects this rung, THEN checks the same predicate again before touching
# anything: (1) a host that never opted into any updater — no legacy agent
# ever existed — must not be silently opted in by this migration; the
# auto-updater stays owner opt-in, exactly as install.sh's setup_root_service
# leaves it. (2) idempotency: a second real run (e.g. --rerun-recorded) with
# the legacy agent already gone has nothing left to converge and says so.
#
# NAMING — GROUND TRUTH, NOT INFERRED FROM THE SPEC. An earlier draft of this
# rung guessed at the legacy labels from the design spec's prose and got it
# wrong in both directions; the names below are read from the actual code
# that mints and kickstarts them.
#
# core/setup/system_service.go:31-37 —
#
#     func (s SystemService) LaunchdLabel() string {
#         return "com.burrowee." + strings.ReplaceAll(s.Name, "-", ".")
#     }
#     // legacyGuiLabel is the pre-rename per-user launchd agent label
#     // (org.burrowee.edge, org.burrowee.edge-updater — hyphen preserved).
#     func (s SystemService) legacyGuiLabel() string { return "org.burrowee." + s.Name }
#
# With Name="<comp>-updater" that gives the SYSTEM target
# "com.burrowee.<comp>.updater" (dots — mirrors inner/edge/install.sh's
# setup_root_service exactly: same label/path shape, same [Service] block,
# same HOME=<root's home> so console.json + identity resolve under the
# root-owned tree) and the legacy GUI-domain label
# "org.burrowee.<comp>-updater" (HYPHEN preserved — the comment above is
# explicit that this is deliberate, not a typo to "fix").
#
# edge/updater.update.sh:140-142 shows a SECOND legacy label actually
# kickstarted in the field today, in the SYSTEM domain:
#
#     launchctl kickstart -k "gui/$(id -u)/org.burrowee.edge-updater"
#     elevate launchctl kickstart -k "system/com.burrowee.edge.updater"
#     elevate launchctl kickstart -k "system/org.burrowee.edge.updater"
#
# — "org.burrowee.<comp>.updater" (DOTTED, system domain): a pre-rename
# SYSTEM LaunchDaemon, distinct from the pre-rename PER-USER agent above.
# Two legacy labels, two domains, and this rung sweeps both:
#
#     org.burrowee.<comp>-updater   gui/<uid>/…   the per-user agent
#     org.burrowee.<comp>.updater   system/…      the pre-rename system unit
#
# "com.burrowee.<comp>-updater" (hyphenated, com prefix) is NOT a real label
# anywhere in edge, gateway, relay or core — that earlier draft invented it
# and would have chased a phantom while missing the real system-domain
# survivor. On Linux the legacy unit is the systemd --user instance of the
# same unit name the system unit now takes; systemd has no second legacy
# domain to sweep.
#
# THE SYSTEM-DOMAIN LEGACY LABEL CAN ITSELF BE THE SUPERVISOR OF THE PROCESS
# RUNNING THIS SCRIPT, exactly like the gui-domain one — a host still on the
# pre-rename "org.burrowee.<comp>.updater" SYSTEM LaunchDaemon runs its
# update.sh under THAT unit. So its bootout is elevated (it is a system-domain
# mutation, like every other write below) but still ordered strictly after
# the new system unit is written and verified loaded — the same reason the
# gui-domain bootout is ordered there, applied to the second domain.
#
# THE COPY IS NOT REIMPLEMENTED HERE, and neither is any state migration — this
# rung touches no file under $COMP_HOME or $COMP_DATA. Only the supervisor
# layer moves; the "never touches enrollment state" promise from the serve
# ladder's rung carries over unchanged.
set -eu

HERE="$(dirname "$0")"

say()  { echo "adopt_updater_unit: $*"; }
warn() { echo "adopt_updater_unit: $*" >&2; }

# lib_paths.sh is the ONE definition of root's home. A second copy of the
# platform-specific /root vs /var/root rule here is exactly the kind of drift
# adopt_user_tree.sh already refuses to risk.
if [ ! -f "$HERE/lib_paths.sh" ]; then
    warn "$HERE/lib_paths.sh is missing — THIS RELEASE IS INCOMPLETE."
    warn "this rung resolves root's home through it and will not guess."
    warn "refusing rather than exiting 0, which would earn a receipt for work that"
    warn "never happened."
    exit 1
fi
# shellcheck source=lib_paths.sh
. "$HERE/lib_paths.sh"

# $COMP comes from run.sh, which resolves it before it runs any rung.
# component.conf is consulted only when it did not — a direct invocation, which
# the header discourages — so the probe answers about the same component the
# runner would have named rather than aborting under `set -u`.
if [ -z "${COMP:-}" ]; then
    if [ -f "$HERE/component.conf" ]; then
        # shellcheck source=/dev/null
        . "$HERE/component.conf"
    fi
    if [ -z "${COMP:-}" ]; then
        warn "no \$COMP and no component.conf — cannot say which component this is."
        exit 1
    fi
fi

BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}"
SUDO="${SUDO:-sudo}"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
LAUNCHD_PLIST_DIR="${LAUNCHD_PLIST_DIR:-/Library/LaunchDaemons}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"

UPDATER_BIN="$BIN_DIR/burrowee-$COMP-updater"

elevate() {
    if [ "$(id -u)" = 0 ]; then "$@"; else $SUDO "$@"; fi
}

# ---------------------------------------------------------------------------
# Platform-specific names, resolved once.
# ---------------------------------------------------------------------------
case "$(uname -s)" in
Darwin)
    SYS_LABEL="com.burrowee.$COMP.updater"
    SYS_PLIST="$LAUNCHD_PLIST_DIR/$SYS_LABEL.plist"
    # See the NAMING section above: core/setup/system_service.go:31-37 +
    # edge/updater.update.sh:140-142. Two legacy labels, two domains.
    LEGACY_GUI_LABEL="org.burrowee.$COMP-updater"
    LEGACY_SYS_LABEL="org.burrowee.$COMP.updater"
    ;;
*)
    SYS_UNIT_NAME="burrowee-$COMP-updater.service"
    SYS_UNIT="$SYSTEMD_UNIT_DIR/$SYS_UNIT_NAME"
    LEGACY_UNIT_NAME="burrowee-$COMP-updater.service"
    ;;
esac

# ---------------------------------------------------------------------------
# legacy_unit_present — whether EITHER legacy agent still exists (gui-domain
# per-user, or system-domain pre-rename unit — see NAMING above), answering
# YES whenever it cannot positively confirm NO for both. The queries
# themselves are unprivileged in both domains — a read, unlike the
# system-domain BOOTOUT in bootout_legacy below, needs no elevation on either
# platform.
# ---------------------------------------------------------------------------
legacy_unit_present() {
    case "$(uname -s)" in
    Darwin)
        command -v "$LAUNCHCTL" >/dev/null 2>&1 || return 0
        # BOTH legacy domains are checked — a host running only the
        # system-domain survivor (org.burrowee.<comp>.updater) and never the
        # gui-domain agent must still be recognised, or this rung silently
        # matches nothing on exactly the hosts it exists for.
        "$LAUNCHCTL" print "gui/$(id -u)/$LEGACY_GUI_LABEL" >/dev/null 2>&1 && return 0
        "$LAUNCHCTL" print "system/$LEGACY_SYS_LABEL" >/dev/null 2>&1 && return 0
        return 1
        ;;
    *)
        command -v "$SYSTEMCTL" >/dev/null 2>&1 || return 0
        "$SYSTEMCTL" --user is-active "$LEGACY_UNIT_NAME" >/dev/null 2>&1 && return 0
        "$SYSTEMCTL" --user is-enabled "$LEGACY_UNIT_NAME" >/dev/null 2>&1 && return 0
        return 1
        ;;
    esac
}

# ---------------------------------------------------------------------------
# --applies: does this host STILL need the convergence?
#
# The only "no" is a positively confirmed absence of the legacy agent — see
# legacy_unit_present. run.sh calls this ONLY when no version is recorded, and
# it has no veto (see run.sh's header on --installed-version).
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--applies" ]; then
    if legacy_unit_present; then exit 0; fi
    exit 1
fi

if [ "${1:-}" != "" ]; then
    warn "unknown argument '$1' (expected --applies or none)"
    exit 2
fi

# ---------------------------------------------------------------------------
# render_launchd_plist / render_systemd_unit — the SAME shape
# inner/edge/install.sh's setup_root_service writes for the updater unit
# (Label/ProgramArguments/RunAtLoad/KeepAlive.PathState/ThrottleInterval on
# macOS; [Service] Type=simple/Restart=always/RestartSec=2/TimeoutStopSec=30 on
# Linux), generalised by $COMP. Kept here rather than deferred to install.sh
# because this migration has to converge a host regardless of which installer
# last ran on it.
# ---------------------------------------------------------------------------
render_launchd_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$SYS_LABEL</string>
  <key>ProgramArguments</key><array><string>$UPDATER_BIN</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$UPDATER_BIN</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict><key>HOME</key><string>$(root_home)</string></dict>
</dict></plist>
EOF
}

render_systemd_unit() {
    cat <<EOF
[Unit]
Description=burrowee $COMP updater
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=$(root_home)
ExecStart=$UPDATER_BIN run
Restart=always
RestartSec=2
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
}

# write_system_unit — STEP 1. Idempotent: overwrites unconditionally with the
# same content every time.
write_system_unit() {
    case "$(uname -s)" in
    Darwin)
        if ! elevate mkdir -p "$LAUNCHD_PLIST_DIR"; then
            warn "could not create $LAUNCHD_PLIST_DIR"
            return 1
        fi
        if ! render_launchd_plist | elevate tee "$SYS_PLIST" >/dev/null; then
            warn "could not write $SYS_PLIST"
            return 1
        fi
        elevate chmod 0644 "$SYS_PLIST" 2>/dev/null || true
        say "wrote $SYS_PLIST"
        ;;
    *)
        if ! elevate mkdir -p "$SYSTEMD_UNIT_DIR"; then
            warn "could not create $SYSTEMD_UNIT_DIR"
            return 1
        fi
        if ! render_systemd_unit | elevate tee "$SYS_UNIT" >/dev/null; then
            warn "could not write $SYS_UNIT"
            return 1
        fi
        elevate chmod 0644 "$SYS_UNIT" 2>/dev/null || true
        say "wrote $SYS_UNIT"
        ;;
    esac
}

# enable_system_unit — STEP 2 (load). Idempotent: bootstrap/enable/kickstart
# and daemon-reload + enable --now are each safe to repeat on an already-loaded
# unit.
enable_system_unit() {
    case "$(uname -s)" in
    Darwin)
        elevate "$LAUNCHCTL" bootout "system/$SYS_LABEL" 2>/dev/null || true
        if ! elevate "$LAUNCHCTL" bootstrap system "$SYS_PLIST"; then
            warn "launchctl bootstrap system $SYS_PLIST failed"
            return 1
        fi
        elevate "$LAUNCHCTL" enable "system/$SYS_LABEL" 2>/dev/null || true
        elevate "$LAUNCHCTL" kickstart -k "system/$SYS_LABEL" 2>/dev/null || true
        ;;
    *)
        elevate "$SYSTEMCTL" daemon-reload 2>/dev/null || true
        if ! elevate "$SYSTEMCTL" enable --now "$SYS_UNIT_NAME"; then
            warn "systemctl enable --now $SYS_UNIT_NAME failed"
            return 1
        fi
        ;;
    esac
}

# verify_system_unit_loaded — STEP 2 (verify), the gate before step 3 ever
# runs. Read-only.
verify_system_unit_loaded() {
    case "$(uname -s)" in
    Darwin) elevate "$LAUNCHCTL" print "system/$SYS_LABEL" >/dev/null 2>&1 ;;
    *)      elevate "$SYSTEMCTL" is-active "$SYS_UNIT_NAME" >/dev/null 2>&1 ;;
    esac
}

# bootout_legacy — STEP 3, both legacy domains. A target that is already gone
# is a normal no-op in either. The gui-domain call is NEVER elevated (see the
# header: this runs as whichever identity is already running the script, and
# on the host this rung exists for that IS the gui-domain agent). The
# system-domain call IS elevated, like every other system-domain mutation
# above — and for the same self-referential reason: a host still on the
# pre-rename system LaunchDaemon runs THIS script under it, so that bootout
# must come after the new system unit is written and verified loaded, never
# before, exactly like the gui-domain one.
bootout_legacy() {
    case "$(uname -s)" in
    Darwin)
        "$LAUNCHCTL" bootout "gui/$(id -u)/$LEGACY_GUI_LABEL" 2>/dev/null || true
        elevate "$LAUNCHCTL" bootout "system/$LEGACY_SYS_LABEL" 2>/dev/null || true
        ;;
    *)
        "$SYSTEMCTL" --user disable --now "$LEGACY_UNIT_NAME" 2>/dev/null || true
        ;;
    esac
}

# ---------------------------------------------------------------------------
# THE REAL RUN — re-checks the SAME predicate --applies used, rather than
# trusting run.sh's earlier call to it: the version gate alone selects this
# rung unconditionally once its target is due, with no --applies veto (see
# run.sh's header), so a host whose legacy agent was cleared by an earlier
# forced run must still see a clean no-op here rather than being silently
# opted into the auto-updater.
# ---------------------------------------------------------------------------
if ! legacy_unit_present; then
    say "no legacy per-user updater agent found for burrowee-$COMP — nothing to converge."
    say "(the auto-updater stays owner opt-in; this migration does not enable it on its own.)"
    exit 0
fi

# EVERY PRE-FLIGHT RUNS BEFORE THE FIRST WRITE, same reasoning as
# adopt_user_tree.sh: discovering a missing binary after the system unit is
# already loading turns a refusal that cost nothing into a unit that can never
# start.
if [ ! -x "$UPDATER_BIN" ]; then
    warn "$UPDATER_BIN is missing — cannot write a system unit that execs it."
    warn "nothing has been written and the legacy per-user updater is untouched."
    exit 1
fi

say "writing the system updater unit for burrowee-$COMP"
if ! write_system_unit; then
    warn "nothing has been loaded and the legacy per-user updater is untouched."
    exit 1
fi

say "loading the system updater unit"
if ! enable_system_unit; then
    warn "the system unit was written but could not be loaded — the legacy per-user"
    warn "updater is UNTOUCHED. Fix the cause above and re-run; every step here is"
    warn "idempotent."
    exit 1
fi

if ! verify_system_unit_loaded; then
    warn "the system unit was written and an enable was attempted, but it does not"
    warn "report loaded/active — REFUSING to boot out the legacy per-user updater"
    warn "while the system one cannot be confirmed up. Nothing legacy has been touched."
    exit 1
fi
say "system updater unit is loaded"

say "booting out the legacy per-user updater agent"
bootout_legacy
say "converged burrowee-$COMP-updater to the system unit"
