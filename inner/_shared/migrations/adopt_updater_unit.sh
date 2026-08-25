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
# STEP 2 PERFORMS A BOOTOUT OF ITS OWN, AND ORDERING DOES NOT PROTECT IT. The
# argument above is about steps 1→3; it says nothing about the fact that
# reloading a launchd system unit is spelled `bootout` + `bootstrap`, and that
# the job being booted out there is $SYS_LABEL — the NEW unit. On a host that is
# already PARTIALLY converged (the new system daemon loaded, a legacy agent
# still around — the state a killed earlier run leaves, and the state this
# rung's own suite constructs), the process walking this ladder is a child of
# THAT job, so an unconditional `bootout system/$SYS_LABEL` here kills its own
# process tree in the middle of step 2: `bootstrap` never runs, the plist is on
# disk with no loaded unit behind it, and recovery needs a reboot or a manual
# bootstrap. Ordering cannot fix this — the kill is inside a step, not between
# two of them — so enable_system_unit below never boots out blind:
#
#   * unit already loaded AND the plist is byte-identical to what this run
#     renders → there is nothing to reload. Ensure it is enabled; return.
#   * unit already loaded, plist CHANGED, and this process's own job IS
#     $SYS_LABEL (launchctl procinfo) → the reload would kill the reloader.
#     Leave it to the caller: <comp>/updater.update.sh's restart_updater runs
#     LAST for exactly this reason, and the next start reads the new plist.
#   * unit not loaded, or loaded from different content under some OTHER job →
#     reload for real; nothing being killed is running this script.
#
# On Linux there is no equivalent hazard: `systemctl enable --now` on an
# already-active unit does not restart it, so step 2 cannot stop the unit
# supervising this process.
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
# "CANNOT TELL" IS A THIRD ANSWER, NOT A SYNONYM FOR "GONE". legacy_unit_state()
# below returns present | absent | unknown, and legacy_unit_present() — the
# --applies predicate — is "not absent", so the contract above holds verbatim.
# The distinction is not academic on Linux: `systemctl --user is-active` exits
# NON-ZERO IDENTICALLY for "the manager says inactive" and "there is no user bus
# to ask", and an earlier draft read both as a confirmed absence. It is told
# apart by the STATE WORD on stdout: a reachable manager always prints one
# (`inactive` even for a unit it has never heard of), an unreachable one prints
# nothing at all. `is-enabled` cannot be used for that test — it prints nothing
# for an unknown unit on a perfectly healthy bus — so is-active is the probe
# that decides reachability and is-enabled only ever adds a "present".
#
# LINUX SCOPE — SYSTEM-SCOPE ONLY. THE PER-USER LINUX CASE IS UNHANDLED, AND
# THAT IS A DECISION, NOT AN OVERSIGHT. The decision is: converge on Linux only
# what this process can POSITIVELY OBSERVE, and say out loud when it cannot
# observe anything. Why the alternative — probing the enrolling user's manager —
# is not available here:
#
#   * <comp>/updater.update.sh installs into $PREFIX/bin unelevated and REFUSES
#     any other destination, so the updater ladder completes on Linux only when
#     it is already root.
#   * root's `systemctl --user` addresses ROOT's user manager, never the
#     enrolling account's. On a stock host root has no user manager at all, so
#     the probe returns "unknown" rather than an answer about the account that
#     actually ran `systemctl --user enable burrowee-<comp>-updater`.
#   * Reaching that account's manager needs its uid (`XDG_RUNTIME_DIR=/run/user/
#     <uid>`, or `systemctl --user -M <user>@`). run.sh exports no account to a
#     rung — see run_migration's env block — and relay, the only component on
#     this ladder that is Linux-first, collapsed to root-only at 0.2.2, so there
#     is no enrolling account recorded anywhere for this rung to read. Guessing
#     one is precisely the "second guess at which user" adopt_user_tree.sh
#     refuses to make.
#   * And a blind convergence would be worse than none: on Linux the legacy unit
#     NAME and the target unit NAME are the same string
#     (burrowee-<comp>-updater.service, differing only in scope), so converging
#     on a "cannot tell" would overwrite the very unit the installer manages
#     with this rung's rendering of it, on every Linux host, forever.
#
# So: unknown on Linux is reported and the run stops, having written nothing —
# a Linux host still running a per-user `systemctl --user`
# burrowee-<comp>-updater is NOT converged by this rung, and the line it prints
# on every update says so. The Darwin branch is unaffected: both of its queries
# (gui/<uid>/… for the running identity, system/… ) are readable without a bus
# and without elevation, so it can always tell.
#
# AN UNELEVATABLE HOST IS DEFERRED (EXIT 3), NEVER FAILED. The headline case for
# this rung is a legacy launchd GUI agent: no tty, no cached sudo credential,
# and $SUDO is `sudo -n`, which never prompts. Every system-domain write below
# therefore fails on exactly the hosts this rung exists for. Failing (exit 1) is
# the one outcome that must not happen: updater.update.sh treats a non-{0,2,3}
# ladder result as fatal and returns BEFORE restart_updater, so the host ends up
# with a new updater binary on disk and its updater service never restarted —
# and the updater is the only automatic delivery channel, so no later release can
# reach it to fix it. A stranded convergence is recoverable; a stopped updater is
# not. The elevate pre-flight below (modelled on adopt_user_tree.sh's) therefore
# detects an unreachable root UP FRONT, before the first write, prints the exact
# command an operator must run, and exits 3 — which run.sh reports as DEFERRED
# (ran nothing, recorded nothing, still pending) and updater.update.sh treats as
# non-fatal, so the service is restarted and the host stays reachable.
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
# The absolute form is only ever used in the operator-facing DEFERRED message
# below: "re-run this" is not actionable when the path is relative to a working
# directory the operator never had. Falls back to $HERE if the cd fails.
HERE_ABS="$(cd "$HERE" 2>/dev/null && pwd)" || HERE_ABS="$HERE"
[ -n "$HERE_ABS" ] || HERE_ABS="$HERE"

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
# legacy_unit_state — THREE answers, printed on stdout:
#
#   present   a legacy agent was positively observed (gui-domain per-user, or
#             system-domain pre-rename unit — see NAMING above).
#   absent    the supervisor answered, and neither legacy agent is there.
#   unknown   nothing could be asked. NOT the same as absent — see "CANNOT TELL
#             IS A THIRD ANSWER" in the header.
#
# The queries are unprivileged on both platforms — a read, unlike the
# system-domain BOOTOUT in bootout_legacy below, needs no elevation.
# ---------------------------------------------------------------------------
legacy_unit_state() {
    case "$(uname -s)" in
    Darwin)
        command -v "$LAUNCHCTL" >/dev/null 2>&1 || { echo unknown; return 0; }
        # BOTH legacy domains are checked — a host running only the
        # system-domain survivor (org.burrowee.<comp>.updater) and never the
        # gui-domain agent must still be recognised, or this rung silently
        # matches nothing on exactly the hosts it exists for.
        if "$LAUNCHCTL" print "gui/$(id -u)/$LEGACY_GUI_LABEL" >/dev/null 2>&1; then
            echo present; return 0
        fi
        if "$LAUNCHCTL" print "system/$LEGACY_SYS_LABEL" >/dev/null 2>&1; then
            echo present; return 0
        fi
        echo absent
        ;;
    *)
        command -v "$SYSTEMCTL" >/dev/null 2>&1 || { echo unknown; return 0; }
        # THE STATE WORD, NOT THE EXIT CODE, is what says whether anyone was
        # home: `is-active` exits non-zero both for "inactive" and for "failed
        # to connect to bus", and only the first of those prints a word. Its
        # stdout is therefore the bus probe as well as the state read, and it
        # has to be the one that decides — `is-enabled` prints nothing for a
        # unit a reachable manager has simply never heard of.
        _lus_active="$("$SYSTEMCTL" --user is-active "$LEGACY_UNIT_NAME" 2>/dev/null || true)"
        if [ -z "$_lus_active" ]; then
            echo unknown; return 0
        fi
        case "$_lus_active" in
        active | activating | reloading | deactivating)
            echo present; return 0
            ;;
        esac
        # The manager answered, so a stopped-but-installed legacy unit is still
        # something to converge — and now `is-enabled`'s silence really does
        # mean "no such unit file" rather than "no bus".
        _lus_enabled="$("$SYSTEMCTL" --user is-enabled "$LEGACY_UNIT_NAME" 2>/dev/null || true)"
        case "$_lus_enabled" in
        "" | disabled | masked* | not-found | bad | invalid)
            echo absent
            ;;
        *)
            echo present
            ;;
        esac
        ;;
    esac
}

# legacy_unit_present — the --applies predicate: "still needed" is anything
# that is not a positively confirmed absence, so `unknown` answers YES. See the
# header.
legacy_unit_present() {
    [ "$(legacy_unit_state)" != absent ]
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
#
# It also RECORDS WHETHER THAT OVERWRITE CHANGED ANYTHING, in
# SYS_UNIT_CHANGED, because this is the last moment the previous content still
# exists to be compared: enable_system_unit runs after the file has already
# been replaced, and "the unit on disk is what I would have written" is the
# fact that lets it skip a reload that would kill the process running it (see
# STEP 2 PERFORMS A BOOTOUT OF ITS OWN in the header). An unreadable existing
# file counts as CHANGED — the conservative direction, since the second guard
# (running_under_sys_label) still stops a self-inflicted bootout.
SYS_UNIT_CHANGED=1

# note_unit_change <rendered> <path> — set SYS_UNIT_CHANGED from a comparison
# of what this run renders against what is already there.
note_unit_change() {
    if [ -f "$2" ] && [ "$1" = "$(cat "$2" 2>/dev/null)" ]; then
        SYS_UNIT_CHANGED=0
    else
        SYS_UNIT_CHANGED=1
    fi
}

write_system_unit() {
    case "$(uname -s)" in
    Darwin)
        if ! elevate mkdir -p "$LAUNCHD_PLIST_DIR"; then
            warn "could not create $LAUNCHD_PLIST_DIR"
            return 1
        fi
        _wsu_body="$(render_launchd_plist)"
        note_unit_change "$_wsu_body" "$SYS_PLIST"
        if ! printf '%s\n' "$_wsu_body" | elevate tee "$SYS_PLIST" >/dev/null; then
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
        _wsu_body="$(render_systemd_unit)"
        note_unit_change "$_wsu_body" "$SYS_UNIT"
        if ! printf '%s\n' "$_wsu_body" | elevate tee "$SYS_UNIT" >/dev/null; then
            warn "could not write $SYS_UNIT"
            return 1
        fi
        elevate chmod 0644 "$SYS_UNIT" 2>/dev/null || true
        say "wrote $SYS_UNIT"
        ;;
    esac
}

# system_unit_loaded — is the NEW system unit already loaded? Read-only, and
# the same query verify_system_unit_loaded makes, kept in one place so "loaded"
# cannot come to mean two different things one line apart.
system_unit_loaded() {
    case "$(uname -s)" in
    Darwin) elevate "$LAUNCHCTL" print "system/$SYS_LABEL" >/dev/null 2>&1 ;;
    *)      elevate "$SYSTEMCTL" is-active "$SYS_UNIT_NAME" >/dev/null 2>&1 ;;
    esac
}

# running_under_sys_label — Darwin only: is THIS process a child of the very
# job a reload would boot out? `launchctl procinfo <pid>` names the job a pid
# belongs to; anything it cannot answer reads as "yes, it might be", because
# the cost of a wrong "no" is a killed process tree mid-convergence and the
# cost of a wrong "yes" is a reload deferred to the caller's restart.
running_under_sys_label() {
    [ "$(uname -s)" = Darwin ] || return 1
    _rus_info="$(elevate "$LAUNCHCTL" procinfo "$$" 2>/dev/null || true)"
    [ -n "$_rus_info" ] || return 0
    case "$_rus_info" in
    *"$SYS_LABEL"*) return 0 ;;
    esac
    return 1
}

# enable_system_unit — STEP 2 (load). Idempotent: bootstrap/enable/kickstart
# and daemon-reload + enable --now are each safe to repeat on an already-loaded
# unit.
#
# IT NEVER BOOTS OUT BLIND. See STEP 2 PERFORMS A BOOTOUT OF ITS OWN in the
# header for the whole argument; the three branches below are its three cases.
enable_system_unit() {
    case "$(uname -s)" in
    Darwin)
        if system_unit_loaded; then
            if [ "$SYS_UNIT_CHANGED" = 0 ]; then
                say "the system updater unit is already loaded from identical content —"
                say "not reloading it (a bootout here would kill the process running this)."
                elevate "$LAUNCHCTL" enable "system/$SYS_LABEL" 2>/dev/null || true
                return 0
            fi
            if running_under_sys_label; then
                say "the system updater unit is already loaded and THIS process runs under it —"
                say "leaving the reload to the caller's restart, which runs last. The new plist"
                say "is on disk and takes effect on that restart."
                elevate "$LAUNCHCTL" enable "system/$SYS_LABEL" 2>/dev/null || true
                return 0
            fi
            # Loaded, changed, and not this process's own job: a real reload,
            # killing nothing that is running this script.
            elevate "$LAUNCHCTL" bootout "system/$SYS_LABEL" 2>/dev/null || true
        fi
        if ! elevate "$LAUNCHCTL" bootstrap system "$SYS_PLIST"; then
            warn "launchctl bootstrap system $SYS_PLIST failed"
            return 1
        fi
        elevate "$LAUNCHCTL" enable "system/$SYS_LABEL" 2>/dev/null || true
        elevate "$LAUNCHCTL" kickstart -k "system/$SYS_LABEL" 2>/dev/null || true
        ;;
    *)
        # No self-kill hazard here: `enable --now` on an already-active unit
        # does not restart it, and daemon-reload restarts nothing.
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
    system_unit_loaded
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
LEGACY_STATE="$(legacy_unit_state)"

if [ "$LEGACY_STATE" = absent ]; then
    say "no legacy per-user updater agent found for burrowee-$COMP — nothing to converge."
    say "(the auto-updater stays owner opt-in; this migration does not enable it on its own.)"
    exit 0
fi

# UNKNOWN IS NOT A LICENCE TO WRITE, on the platform where "unknown" is the
# permanent answer. See LINUX SCOPE in the header: root cannot reach the
# enrolling account's systemd user manager, the runner has no account to hand
# this rung, and the Linux legacy unit and the target unit share a NAME — so
# converging on a guess would overwrite the installer's own unit on every Linux
# host. Said out loud rather than skipped silently: an operator reading an
# update log must be able to see that this rung did not cover their host.
if [ "$LEGACY_STATE" = unknown ] && [ "$(uname -s)" != Darwin ]; then
    say "cannot reach a systemd USER manager from this process, so whether"
    say "burrowee-$COMP-updater still runs as a per-user unit is unknowable here."
    say "OUT OF SCOPE — this rung converges a Linux host only from what it can"
    say "positively observe (see its header, LINUX SCOPE). Nothing has been written"
    say "and nothing legacy has been touched."
    say "IF this host still runs burrowee-$COMP-updater as a per-user unit, run this"
    say "rung AS THAT ACCOUNT — from there its manager IS reachable, and it elevates"
    say "for the system-side writes on its own:"
    say "    sh $HERE_ABS/adopt_updater_unit.sh"
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

# ROOT IS REACHED, OR THIS RUN IS DEFERRED — never failed. adopt_user_tree.sh
# models the probe; the exit code is what differs, and why is the header's
# "AN UNELEVATABLE HOST IS DEFERRED" section: exit 1 here would abort
# updater.update.sh before it restarts the updater service, on precisely the
# hosts whose legacy gui agent has no tty and no cached sudo credential, and a
# host whose updater never restarts cannot be reached by any later release.
if ! elevate true >/dev/null 2>&1; then
    warn "this run cannot reach root ('$SUDO' did not run for us), and every step of"
    warn "this convergence writes into a system domain."
    warn "DEFERRED — nothing has been written, nothing has been loaded, and the legacy"
    warn "updater agent is UNTOUCHED, so this host keeps updating exactly as it did."
    warn "AN OPERATOR MUST RUN THIS ONCE, ON THIS HOST:"
    warn "    sudo sh $HERE_ABS/adopt_updater_unit.sh"
    warn "until then every update re-attempts it and re-prints this — a deferred rung"
    warn "records no version and stays pending."
    exit 3
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
