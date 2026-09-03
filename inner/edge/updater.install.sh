#!/bin/sh
# Burrowee inner installer — edge UPDATER ONLY (POSIX sh, macOS + Linux).
#
# THE UPDATER IS THE ONLY AUTOMATIC DELIVERY CHANNEL, and it has no path back
# to itself. A push update rewrites the serve binary via burrowee-edge-updater
# — never the updater's own binary or unit — and the ONLY thing that places
# the updater's binary + unit is the full component installer (install.sh,
# this file's sibling). So a node whose updater is stale, stopped, or was
# never installed at all cannot be reached by shipping another release: the
# one thing that would fetch it is the thing that is broken. This script is
# the narrow tool that puts the updater back without depending on it —
# `curl -fsSL release.burrowee.com/edge/updater.install.sh | sh`.
#
# *** ENROLLMENT-PRESERVING — CRITICAL ***
# Touches ONLY the updater binary + its unit. NEVER renames, moves, backs up,
# or deletes $HOME/.burrowee/edge, /usr/local/burrowee/etc/edge (nor a 0.2
# host's not-yet-migrated /usr/local/etc/burrowee/edge), or anything
# under any of them — the full installer's ladder owns that state; this script
# does not resolve a component home at all. Its own migration step (below)
# walks the updater's ladder against a THROWAWAY scratch tree, never the real
# one, so that promise holds structurally rather than by convention.
#
# It also converges a legacy PER-USER updater agent onto the managed system
# unit, by running the same ladder update.sh runs (migrations/updater-ledger).
# Installing the system unit beside a live legacy agent would leave TWO
# updaters running — worse than the stale/missing one this script exists to
# fix — so that convergence rung is not optional here.
#
# Unlike install.sh's default (the updater unit is rendered but left owner
# opt-in), this script ENABLES and STARTS it: an operator running this one
# specifically wants the updater running now.
#
# Env seams (production defaults shown; override in tests to avoid systemd):
#   SYS_BIN_DIR   the one binary destination (default: /usr/local/burrowee/bin,
#                 the machine-owned tree's bin/)
#   PREFIX        install prefix — see the guard below. ROOT-ONLY: a PREFIX
#                 naming any OTHER destination is refused, not honored. An
#                 accepted one is UNSET before anything downstream runs.
#   SUDO          elevation command (default: sudo -n — never prompts, so a
#                 daemon-driven run cannot hang on a password)
#   SYSTEMCTL     systemctl binary (default: systemctl)
set -eu

# ── the destination guard — BYTE-IDENTICAL copy of inner/edge/install.sh's
# (task-1-brief decision: copy verbatim, never retype/improve/reflow; a later
# task pins these copies byte-identical across every inner/ script, and a
# drifted copy is exactly what that pin exists to catch). Comments below
# still say "install:" because they are the copied text, unchanged.
# ── system install paths ─────────────────────────────────────────────────────
# SYS_BIN_DIR + SYSTEMD_UNIT_DIR + LAUNCHD_PLIST_DIR default to the real system
# locations; they are overridable only so the Go install-test harness can
# exercise this script in a sandbox without actually being root — never set them
# on a real host. SYS_BIN_DIR is this component's equivalent of the gateway's
# BURROWEE_BIN_DIR seam; it keeps its name because the rendered units, and every
# caller that already sets it, are written in terms of it.
#
# SYS_BIN_DIR and BIN_DIR are resolved BEFORE the PREFIX gate below, because the
# gate's whole question is "does this PREFIX name the destination we would have
# picked anyway?" — it cannot ask that without $BIN_DIR. These are assignments
# only: nothing is created, placed or written until well after the gate.
SYS_BIN_DIR="${SYS_BIN_DIR:-/usr/local/burrowee/bin}"
# BIN_DIR and SYS_BIN_DIR are ONE destination under two names: the units and the
# test harness spell it SYS_BIN_DIR, the placement/uninstall code below spells it
# BIN_DIR, and since the 0.2.0 collapse they can never differ. Resolved HERE, at
# the top, rather than beside the config home further down — the shared sweep
# library reads $BIN_DIR for the guard that refuses to sweep the install
# destination, and a library sourced before the value was decided would have
# taken the production default while this run installed somewhere else.
BIN_DIR="$SYS_BIN_DIR"
# The 0.2 exec root and the operator-typed names, for the ladder invocation
# below. This track never links anything itself, so it hands the rung the full
# set as "keep": with no link replacing them, the real 0.2 file at each of those
# names is the only copy anything reaches by the absolute path. Left unset, the
# runner would default LEGACY_BIN_DIR to the REAL /usr/local/bin even under a
# fully seamed test, and sweep with an empty keep-list.
LEGACY_BIN_DIR="${LEGACY_BIN_DIR:-${BURROWEE_LINK_DIR:-/usr/local/bin}}"
LINK_BINS="burrowee burrowee-edge burrowee-edge-cli"

# normalize_dir PATH — collapse repeated slashes and strip trailing ones, so
# '/usr/local/bin', '/usr/local//bin' and '/usr/local/bin/' all name the same
# directory. Root ('/') stays '/'. Used ONLY to compare two directory names.
#
# printf '%s', NEVER echo. dash's echo (and bash's under xpg_echo) expands
# backslash escapes in its argument, so an echo-based normaliser reduces
# PREFIX='/usr/local/bin\c' to '/usr/local/bin' and ACCEPTS a prefix that is not
# this destination at all — the one thing this gate exists to catch.
#
# TEXTUAL ONLY — no '.'/'..' folding, no symlink resolution, no relative-path
# anchoring. A PREFIX spelled '/usr/local/../local' or '/usr/local/.' is NOT
# recognised as the destination and is refused. Deliberate and sufficient: the
# one value this has to recognise is core's injected PREFIX, which is already
# filepath.Dir-clean and absolute, and a guard that resolved symlinks would be
# claiming to know where a path LANDS, which is a different (and racy) question
# from the one being asked here.
normalize_dir() {
    _nd="$(printf '%s' "$1" | sed -e 's|//*|/|g' -e 's|/*$||')"
    printf '%s' "${_nd:-/}"
}

# A DIVERGENT PREFIX IS REFUSED — a PREFIX that names THIS destination is not —
# and it is refused HERE, before a directory is created, a binary placed or a
# unit written. Refusing the divergent one is the point: an operator who typed
# PREFIX=$HOME/.local and got a root-owned /usr/local/bin would be handed exactly
# the class of surprise this collapse exists to remove, one direction reversed.
# They get told instead, and the process that set it (a shell profile, an outer
# bootstrap, a wrapper) is the thing that has to change. The version is named
# because the operator hitting this needs to know since when; it is asserted by
# the suite (install_test/root_only_test.go), so it cannot drift away from the
# release it describes without a test failing.
#
# But refusing EVERY set PREFIX refuses callers that are naming the one true
# destination, which misdirects nothing — and that blanket shape is what wedged
# relay's entire fleet on 2026-08-22: core's updater injects
# PREFIX=<dirname²(ServeBin)> = /usr/local when it runs these scripts, so every
# auto/push update died with "PREFIX is set to '/usr/local' … nothing has been
# updated". Today this installer survives that only because core strips PREFIX
# for root-only components before exec — i.e. the fresh-install path is protected
# by a Go change rather than by the rule. The rule is the guard's subject: a copy
# landing where the units never execute, and only that.
if [ -n "${PREFIX:-}" ]; then
    _prefix_bin="$(normalize_dir "$PREFIX/bin")"
    _true_bin="$(normalize_dir "$BIN_DIR")"
    if [ "$_prefix_bin" = "$_true_bin" ]; then
        # printf, not echo, for every line that interpolates the caller's own
        # value: dash's echo would expand a backslash escape inside $PREFIX and
        # silently truncate the very line meant to quote it back.
        printf '%s\n' "install: PREFIX ('$PREFIX') names this installer's own destination ($_true_bin) — proceeding."
        # Absent, not empty: an ACCEPTED PREFIX is cleared right here, so nothing
        # downstream can read it as a fallback. The migration ladder is handed
        # its environment with the `VAR=x sh run.sh` form, which ADDS to the
        # environment rather than replacing it, and the shared rungs read
        # BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}" — harmless only while
        # BIN_DIR is passed explicitly and wins, i.e. one deletion away from
        # mattering. Cleared, never set to "": absent, not empty, as core does it.
        unset PREFIX
    else
        # The refusal carries BOTH spellings of the destination: the literal
        # /usr/local/burrowee/bin (production truth, and what the suite's static
        # pins check) and the resolved $_true_bin. They differ only when the
        # SYS_BIN_DIR test seam is set, and an operator reading a refusal on a
        # real host must see the real path either way.
        #
        # printf, not echo, on the two lines that interpolate caller-controlled
        # text: a PREFIX containing a backslash escape ('\c' ends echo's output
        # in dash) would otherwise truncate the refusal at the moment it quotes
        # the offending value, hiding the component, the destination and the
        # "nothing has been installed" line all at once.
        printf '%s\n' "install: PREFIX is set to '$PREFIX', but as of edge 0.2.0 this installer" >&2
        echo "install: has one destination: /usr/local/burrowee/bin, root-owned. The per-user" >&2
        echo "install: prefix flow is gone — edge's service units run as root and name the" >&2
        echo "install: binaries absolutely, and other components resolve" >&2
        echo "install: /usr/local/burrowee/bin/burrowee by absolute path, so a per-user copy" >&2
        echo "install: is invisible to both." >&2
        printf '%s\n' "install: (a PREFIX resolving to $_true_bin is honoured; '$_prefix_bin' is not it.)" >&2
        echo "hint: unset PREFIX and re-run; nothing has been installed." >&2
        exit 1
    fi
    unset _prefix_bin _true_bin
fi
# ── end of the byte-identical guard copy ─────────────────────────────────────

SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
SYSTEMD_UPDATER_UNIT="$SYSTEMD_UNIT_DIR/burrowee-edge-updater.service"
LAUNCHD_PLIST_DIR="${LAUNCHD_PLIST_DIR:-/Library/LaunchDaemons}"
LAUNCHD_UPDATER_PLIST="$LAUNCHD_PLIST_DIR/com.burrowee.edge.updater.plist"
LAUNCHD_UPDATER_LABEL="com.burrowee.edge.updater"

SYSTEMCTL="${SYSTEMCTL:-systemctl}"
SUDO="${SUDO:-sudo -n}"

# elevate CMD… — run CMD as root: directly when already root, else through
# $SUDO. Documented as `curl ... | sh` (no sudo prefix) precisely because this
# script self-elevates every privileged step, mirroring updater.update.sh's
# own elevate — the invoking shell is not assumed to already be root.
elevate() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    else
        $SUDO "$@"
    fi
}

# MIGRATIONS_DIR resolved early (not just beside the ladder invocation below):
# lib_paths.sh's root_home() is the one implementation of the /root vs
# /var/root rule, and the unit render below needs ROOT_HOME before the ladder
# ever runs. The inline fallback is reached only by a bundle carrying no
# migrations/ at all.
MIGRATIONS_DIR=""
if [ -d "$(dirname "$0")/migrations" ]; then
    MIGRATIONS_DIR="$(dirname "$0")/migrations"
fi
if [ -n "$MIGRATIONS_DIR" ] && [ -f "$MIGRATIONS_DIR/lib_paths.sh" ]; then
    # shellcheck source=/dev/null
    . "$MIGRATIONS_DIR/lib_paths.sh"
fi
if command -v root_home >/dev/null 2>&1; then
    ROOT_HOME="$(root_home)"
elif [ "$(uname -s)" = "Darwin" ]; then
    ROOT_HOME="${ROOT_HOME:-$(eval echo ~root)}"
    case "$ROOT_HOME" in /*) ;; *) ROOT_HOME=/var/root ;; esac
else
    ROOT_HOME="${ROOT_HOME:-/root}"
fi

# place_bin SRC DST — install a 0755 binary and strip the macOS quarantine
# xattr. Elevated (see elevate's comment above): unlike updater.update.sh,
# which runs FROM the already-privileged updater daemon, this script is the
# fresh `curl | sh` entrypoint and cannot assume the invoking shell is root.
# ensure_exec_root_stated — create the exec root and its parent with the mode
# STATED, never inherited. `mkdir -p` under sudo creates 0777 &^ umask, so an
# operator with `umask 002` gets 0775 — group-writable, which dir_is_root_secure
# refuses and which this script would then render a root unit inside. This is a
# `curl | sh` entrypoint of its own, so it can be the first thing to create the
# tree; the full installer states every level the same way (ensure_system_tree).
ensure_exec_root_stated() {
    _eers_d="$1"
    _eers_p="$(dirname "$_eers_d")"
    for _eers_l in "$_eers_p" "$_eers_d"; do
        [ -d "$_eers_l" ] || elevate mkdir "$_eers_l" || return 1
        elevate chmod 755 "$_eers_l" || return 1
        elevate chown 0 "$_eers_l" 2>/dev/null || true
    done
}

place_bin() {
    ensure_exec_root_stated "$(dirname "$2")"
    elevate install -m 0755 "$1" "$2"
    if [ "$(uname -s)" = "Darwin" ]; then
        elevate xattr -d com.apple.quarantine "$2" 2>/dev/null || true
    fi
}

# ── place ONLY the updater binary (fail loudly if missing) ────────────────────
[ -f "./burrowee-edge-updater" ] || {
    echo "updater.install.sh: missing burrowee-edge-updater in release dir" >&2
    exit 1
}
place_bin "./burrowee-edge-updater" "$BIN_DIR/burrowee-edge-updater"
echo "updater.install.sh: placed $BIN_DIR/burrowee-edge-updater"

# ── write the updater unit (system-scope). Rendering ONLY — no load/start
# here; that happens after the ladder below, same reason install.sh keeps
# the "already loaded" bootout+bootstrap dance in one place: a reload before
# the ladder has had a chance to converge a legacy agent would be a second,
# uncoordinated writer of the same unit. ────────────────────────────────────
if [ "$(uname -s)" = "Darwin" ]; then
    _unit_body="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCHD_UPDATER_LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN_DIR/burrowee-edge-updater</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$BIN_DIR/burrowee-edge-updater</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict><key>HOME</key><string>$ROOT_HOME</string></dict>
</dict></plist>
EOF
)"
    elevate mkdir -p "$LAUNCHD_PLIST_DIR"
    printf '%s\n' "$_unit_body" | elevate tee "$LAUNCHD_UPDATER_PLIST" >/dev/null
    elevate chmod 0644 "$LAUNCHD_UPDATER_PLIST"
    echo "updater.install.sh: wrote LaunchDaemon → $LAUNCHD_UPDATER_PLIST"
else
    _unit_body="$(cat <<EOF
[Unit]
Description=burrowee edge updater
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
ExecStart=$BIN_DIR/burrowee-edge-updater run
Restart=always
RestartSec=2
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
)"
    elevate mkdir -p "$SYSTEMD_UNIT_DIR"
    printf '%s\n' "$_unit_body" | elevate tee "$SYSTEMD_UPDATER_UNIT" >/dev/null
    elevate chmod 0644 "$SYSTEMD_UPDATER_UNIT"
    echo "updater.install.sh: wrote systemd unit → $SYSTEMD_UPDATER_UNIT"
fi

# ── THE UPDATER'S OWN LADDER ───────────────────────────────────────────────────
# migrations/updater-ledger, walked by the SAME shared runner (migrations/run.sh)
# update.sh uses, but pointed at a SEPARATE ledger — see
# inner/_shared/migrations/adopt_updater_unit.sh's header for why the serve
# ladder structurally cannot converge a legacy updater agent, and why this
# track is the one place that is allowed to.
#
# *** ENROLLMENT-PRESERVING, EVEN HERE ***. The runner's own bookkeeping — the
# version anchor and the per-item receipts — normally lives INSIDE $COMP_HOME,
# exactly the tree this script's header promises never to touch. So this
# ladder is walked against a THROWAWAY scratch tree, never a real component
# home: adopt_updater_unit.sh is independently idempotent (its own --applies
# probe re-examines the live supervisor state on every run), so losing the
# runner's receipt between runs costs nothing but a cheap re-probe.
#
# A rung returning 3 means it ran nothing and stopped nothing (DEFERRED, not
# failed) — the binary above is already placed and the unit already written;
# only 1 (anything else) means the ladder itself refused or broke, which stops
# this script before the unit is ever loaded.
MIGRATIONS_DIR=""
if [ -d "$(dirname "$0")/migrations" ]; then
	MIGRATIONS_DIR="$(dirname "$0")/migrations"
fi
if [ -n "$MIGRATIONS_DIR" ] && [ -f "$MIGRATIONS_DIR/run.sh" ] && [ -f "$MIGRATIONS_DIR/updater-ledger" ]; then
	_ul_home="$(mktemp -d 2>/dev/null)" || _ul_home=""
	if [ -z "$_ul_home" ]; then
		echo "updater.install.sh: could not create a scratch tree for the updater ladder — skipping it." >&2
	else
		# adopt_updater_unit.sh deliberately restarts the updater's own supervisor,
		# so this process being killed mid-run is EXPECTED, not hypothetical.
		trap 'rm -rf "$_ul_home"' EXIT INT TERM HUP
		set +e
		LEDGER_FILE="$MIGRATIONS_DIR/updater-ledger" \
			COMP_HOME="$_ul_home" \
			COMP_DATA="$_ul_home" \
			BIN_DIR="$BIN_DIR" \
			LEGACY_BIN_DIR="$LEGACY_BIN_DIR" \
			STALE_EXEC_ROOT_KEEP="$LINK_BINS" \
			SUDO="$SUDO" \
			SYSTEMCTL="$SYSTEMCTL" \
			sh "$MIGRATIONS_DIR/run.sh"
		_ul_rc=$?
		set -e
		rm -rf "$_ul_home"
		case "$_ul_rc" in
		0 | 2 | 3) ;;
		*)
			echo "updater.install.sh: the updater's own state migration refused or failed — stopping." >&2
			echo "updater.install.sh: the updater binary is in $BIN_DIR; nothing else has been changed." >&2
			exit 1
			;;
		esac
	fi
fi

# $_RUNROOT / $_SYSTEMCTL — the two seams the start helpers below are
# parameterised on. Those bodies are byte-identical across the four inner
# installers and pinned that way (tools/prefix-gate-drift.test.sh), so anything
# that legitimately differs between them has to be a variable read by the body,
# never an edit to the body — and never a wrapper at the call site either, since
# `$_RUNROOT cmd` with _RUNROOT=run_root expands to a function call and a call
# site cannot reach inside the helper's own launchctl/systemctl invocations.
#
# This script self-elevates per command and is documented as `curl … | sh` with
# no sudo prefix, so the invoking shell is NOT assumed to be root: elevate is
# how every other privileged step here reaches root, and the start helpers use
# the same door. $SYSTEMCTL is this file's declared test seam (see the header),
# so the helper reaches systemctl through it rather than around it.
_RUNROOT="elevate"
_SYSTEMCTL="$SYSTEMCTL"

# start_unit_darwin <label> <plist> — start a launchd system unit and verify it
# took. bootstrap's codes 5 (already loaded) and 37 are benign races against an
# async bootout — every other code is a real failure and must not be swallowed.
# enable + kickstart ALWAYS run: a bootstrap that no-ops on an already-loaded
# label still needs both.
#
# The status is captured with `|| _rc=$?`, NOT inside `if ! ...`: POSIX makes $?
# the NEGATED status of a `!` pipeline, so an `if !` branch would read 0 for
# every failure and tolerate nothing.
#
# EVERY launchctl CALL GOES THROUGH $_RUNROOT, and that is not decoration. Only
# one of the four scripts carrying this body refuses to run as anything but
# root; the other three are entered by an unprivileged shell and elevate per
# command. Unprivileged on macOS, `launchctl bootstrap` exits 5 — a code the
# case below TOLERATES as "already loaded" — and `launchctl print` exits 113, so
# a bare-launchctl body would sail past the guard, have enable and kickstart
# denied and swallowed, and then abort at the probe with the daemon already
# booted out by the caller. Silent non-elevation is the one failure this helper
# cannot see.
start_unit_darwin() {
    _label="$1"; _plist="$2"
    _rc=0
    $_RUNROOT launchctl bootstrap system "$_plist" 2>/dev/null || _rc=$?
    case "$_rc" in
        0 | 5 | 37) ;; # started / already loaded / async bootout still settling
        *)
            echo "error: launchctl bootstrap $_label failed (exit $_rc)" >&2
            echo "hint: sudo launchctl bootstrap system $_plist" >&2
            return 1
            ;;
    esac
    # enable + kickstart ALWAYS run, and their failures are deliberately funnelled
    # into the probe below rather than aborting under set -e: the probe is the only
    # thing that reports the label and a recovery command. `|| true` is safe here
    # ONLY because a verification immediately follows it — never widen it further.
    $_RUNROOT launchctl enable "system/$_label" 2>/dev/null || true
    $_RUNROOT launchctl kickstart -k "system/$_label" 2>/dev/null || true
    if $_RUNROOT launchctl print "system/$_label" >/dev/null 2>&1; then
        echo "launchd service $_label enabled + started"
    else
        echo "error: $_label did not come up after bootstrap" >&2
        echo "hint: sudo launchctl print system/$_label" >&2
        return 1
    fi
}

# start_unit_linux <unit> — enable, (re)start and verify a systemd system unit.
# The probe is the point: enable --now on a unit that then dies must not be
# reported as a started service.
#
# $_RUNROOT for the same reason as start_unit_darwin above; $_SYSTEMCTL because
# two of the four scripts carrying this body declare a $SYSTEMCTL test seam and
# still route every other systemctl call through it — a bare `systemctl` here
# would be the one call that escaped it.
start_unit_linux() {
    _unit="$1"
    # Failures here are funnelled into the is-active probe below rather than
    # aborting under set -e: the probe is the only thing that reports the unit and
    # a recovery command. `|| true` is safe here ONLY because a verification
    # immediately follows it — never widen it further.
    $_RUNROOT "$_SYSTEMCTL" enable --now "$_unit" 2>/dev/null || true
    $_RUNROOT "$_SYSTEMCTL" restart "$_unit" 2>/dev/null || true
    if $_RUNROOT "$_SYSTEMCTL" is-active --quiet "$_unit"; then
        echo "systemd service $_unit enabled + (re)started"
    else
        echo "error: $_unit is not active after enable --now" >&2
        echo "hint: sudo $_SYSTEMCTL status $_unit" >&2
        return 1
    fi
}

# ── start the updater. Unlike install.sh's default (rendered but left owner
# opt-in), this script enables and starts it — an operator running this one
# specifically wants the updater running now. Bootout-then-reload (Darwin) /
# daemon-reload+enable+restart (Linux) mirrors install.sh's own idempotent
# reload of the serve unit, applied here to the updater's. This is a recovery
# tool run precisely on hosts where the label is already loaded, so the
# bootstrap's benign-already-loaded codes must not abort before enable/
# kickstart ever run — routed through start_unit_darwin / start_unit_linux
# (copied byte-identical from inner/edge/install.sh) for that reason. These
# unconditionally start the updater — that is this script's entire purpose —
# and deliberately do NOT honour BURROWEE_NO_UPDATER: running the updater
# installer while asking for no updater is a contradiction that flag does not
# reach here. ──────────────────────────────────────────────────────────────
if [ "$(uname -s)" = "Darwin" ]; then
    elevate launchctl bootout "system/$LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
    start_unit_darwin "$LAUNCHD_UPDATER_LABEL" "$LAUNCHD_UPDATER_PLIST"
else
    elevate "$SYSTEMCTL" daemon-reload
    start_unit_linux burrowee-edge-updater
fi


# ---------------------------------------------------------------------------
# print_path_advice — the "Next steps" block this install ends with, rendered
# for the INVOKING operator's login shell by render_path_advice, which lives
# inside the byte-pinned SHARED SWEEP CONTRACT region of the shared sweep
# library beside this script.
#
# IT IS WHAT REPLACED THE /usr/local/bin SYMLINKS. The exec root is $BIN_DIR,
# which is on nobody's PATH; the operator-typed names used to be linked back
# into /usr/local/bin to compensate, and on a clean modern Mac that directory
# does not exist — so nothing was linked and the install ended with no command
# the operator could type.
#
# THIS SCRIPT PLACES ONLY THE UPDATER, which nobody types, and prints the block
# anyway: it is the recovery entry point, reached exactly when the component's
# normal channel is broken, and the operator standing at that prompt still has
# an exec root nothing on their PATH can see.
#
# NEVER FATAL, AND NEVER SILENT. It runs past every write; dying under `set -eu`
# with "not found" would report a complete install as a failure. A kit whose
# library predates the renderer still owes the operator the one line that makes
# these commands reachable, so the fallback prints it by hand.
# ---------------------------------------------------------------------------
print_path_advice() {
    if ! command -v render_path_advice >/dev/null 2>&1; then
        if [ -n "${MIGRATIONS_DIR:-}" ] && [ -f "$MIGRATIONS_DIR/lib_stale_user_bins.sh" ]; then
            # LIB_STALE_USER_BINS_DIR pins where the library finds its siblings:
            # sourced from here $0 is the BUNDLE ROOT, not migrations/.
            LIB_STALE_USER_BINS_DIR="$MIGRATIONS_DIR"
            export LIB_STALE_USER_BINS_DIR
            # shellcheck source=/dev/null
            . "$MIGRATIONS_DIR/lib_stale_user_bins.sh"
        fi
    fi
    if command -v render_path_advice >/dev/null 2>&1; then
        render_path_advice "$BIN_DIR"
        return 0
    fi
    echo "note: the loaded sweep library has no render_path_advice — this kit predates the" >&2
    echo "note: shell-aware PATH advice, so here is the one line it would have rendered." >&2
    echo ""
    echo "==> Next steps"
    echo "burrowee's commands are in $BIN_DIR, which is not on your PATH."
    echo ""
    echo "  Add it to this shell now:"
    echo "    export PATH=\"$BIN_DIR:\$PATH\""
    echo ""
    echo "  Then:  burrowee help"
    return 0
}

echo "updater.install.sh: updater install complete."

# The last thing printed: the operator's own next step. Unconditional on the
# success path — under `sudo` this process sees root's secure_path and cannot
# observe the operator's interactive PATH, so "is it already on PATH?" is a
# question it must not pretend to have answered.
print_path_advice
