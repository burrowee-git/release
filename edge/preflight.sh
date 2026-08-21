#!/bin/sh
# Burrowee preflight — OS-dependency installer (POSIX sh, macOS + Linux).
#
# Run BEFORE the trust gate in <comp>/install.sh: it installs the OS packages the
# installer (and a self-hosted edge) needs — minisign + unzip for the trust gate,
# nginx + the stream module for an edge — using root, so the trust gate and the
# post-pairing `doctor --fix` never hit an "are you root?" / "command not found".
#
# It only ever invokes the OS package manager (apt/dnf/apk/brew), whose repos are
# themselves signed, so minisign still arrives from a trusted channel. This file's
# own sha256 is baked into install.sh and verified before it is run.
#
# DO NOT EDIT generated copies (edge/preflight.sh) by hand — they are produced
# from tools/preflight.template.sh by tools/gen-bootstraps.sh.
#
# Env vars:
#   BURROWEE_SKIP_NGINX       set to skip the nginx group entirely (edge only)
#   BURROWEE_NGINX_INSTALL    1 = install nginx without asking; 0 = never ask, print tips
#   BURROWEE_PREFLIGHT_DRY    set to print the verbs it WOULD run and install nothing
#   BURROWEE_PREFLIGHT_NO_TTY test-only: pretend /dev/tty is absent

set -eu

# ---- knobs --------------------------------------------------------------
COMP="edge"
NGINX="1"               # 1 for edge, 0 for cli/gateway/agent
DRY="${BURROWEE_PREFLIGHT_DRY:-}"

# ---- helpers ------------------------------------------------------------
fail() { printf '\n  ✗ %s\n\n' "$*" >&2; exit 1; }
info() { printf '  → %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

# ---- platform detection -------------------------------------------------
case "$(uname -s)" in
    Darwin) OS=darwin ;;
    Linux)  OS=linux ;;
    *)      fail "unsupported OS: $(uname -s) (burrowee ships darwin + linux only)" ;;
esac
case "$(uname -m)" in
    arm64|aarch64) ARCH=arm64 ;;
    x86_64|amd64)  ARCH=amd64 ;;
    *)             fail "unsupported arch: $(uname -m) (burrowee ships arm64 + amd64 only)" ;;
esac

printf '\n  burrowee %s preflight  (%s/%s)\n\n' "$COMP" "$OS" "$ARCH"

# running tallies for the final summary
N_INSTALLED=0
N_SKIPPED=0
N_WARNED=0

# ---- package-manager detection (first found wins) -----------------------
# PM = apt|dnf|apk|brew. INSTALL/UPDATE/ENABLE are command strings (sans root
# prefix); ROOT is prepended per §root acquisition below.
PM=""
if command -v apt-get >/dev/null 2>&1; then
    PM=apt
elif command -v dnf >/dev/null 2>&1; then
    PM=dnf; DNF_BIN=dnf
elif command -v yum >/dev/null 2>&1; then
    PM=dnf; DNF_BIN=yum
elif command -v apk >/dev/null 2>&1; then
    PM=apk
elif command -v brew >/dev/null 2>&1; then
    PM=brew
fi

if [ -z "$PM" ]; then
    warn "no supported package manager found (apt/dnf/yum/apk/brew)"
    info "install these by hand, then re-run the installer:"
    info "  required:    minisign unzip curl ca-certificates"
    [ "$NGINX" = 1 ] && info "  edge: nginx + its stream module as a root/system service (see release.burrowee.com docs)"
    info "  best-effort: netcat openssl jq"
    # SOFT exit — the installer's trust gate is the backstop for the required tools.
    exit 0
fi
info "package manager: $PM"

# ---- root acquisition ---------------------------------------------------
# ROOT is the prefix for install/enable verbs. brew refuses root, so on brew it
# stays empty (and we never sudo on macOS). For the others: direct if euid 0,
# else sudo if present, else print the commands and exit 1 (non-fatal to the
# caller — install.sh treats a preflight non-zero as "continue, trust gate verifies").
ROOT=""
if [ "$PM" != brew ]; then
    if [ "$(id -u)" = 0 ]; then
        ROOT=""
    elif command -v sudo >/dev/null 2>&1; then
        ROOT="sudo"
    else
        warn "not root and sudo not found — cannot install OS packages"
        info "re-run as root, or run these by hand:"
        case "$PM" in
            apt) info "  apt-get update && apt-get install -y minisign unzip curl ca-certificates" ;;
            dnf) info "  ${DNF_BIN} install -y minisign unzip curl ca-certificates" ;;
            apk) info "  apk add minisign unzip curl ca-certificates" ;;
        esac
        [ "$NGINX" = 1 ] && [ -z "${BURROWEE_SKIP_NGINX:-}" ] && info "  edge: nginx + its stream module as a root/system service (see release.burrowee.com docs)"
        exit 1
    fi
fi

# ---- run / dry-run shim -------------------------------------------------
# run <verb...> — execute a privileged verb (or just print it under DRY).
# shellcheck disable=SC2086  # $ROOT is an intentional optional-prefix word (empty or "sudo").
run() {
    if [ -n "$DRY" ]; then
        printf '  [dry] %s %s\n' "$ROOT" "$*" | sed 's/^\(  \[dry\]\) \+/\1 /'
        return 0
    fi
    $ROOT "$@"
}

# present <name> — true if a command (or, for nginx, the binary) is already installed.
present() {
    case "$1" in
        nginx) command -v nginx >/dev/null 2>&1 || nginx -v >/dev/null 2>&1 ;;
        *)     command -v "$1" >/dev/null 2>&1 ;;
    esac
}

# ---- per-manager install verbs ------------------------------------------
APT_UPDATED=0
pm_install() {
    # pm_install <pkg...> — install one or more packages with the detected manager.
    case "$PM" in
        apt)
            if [ "$APT_UPDATED" = 0 ]; then
                run apt-get update
                APT_UPDATED=1
            fi
            run apt-get install -y "$@"
            ;;
        dnf)  run "$DNF_BIN" install -y "$@" ;;
        apk)  run apk add "$@" ;;
        brew) run brew install "$@" ;;
    esac
}

# ---- install one logical tool, idempotent + tallied ---------------------
# need_tool <command-to-probe> <severity> <pkg...>
#   severity: required | best   (controls whether a failure warns or is silent-skip)
need_tool() {
    probe="$1"; sev="$2"; shift 2
    if present "$probe"; then
        ok "$probe already present"
        N_SKIPPED=$((N_SKIPPED + 1))
        return 0
    fi
    info "installing $probe ($*)"
    if pm_install "$@"; then
        if [ -n "$DRY" ] || present "$probe"; then
            ok "$probe installed"
            N_INSTALLED=$((N_INSTALLED + 1))
        else
            warn "$probe still not on PATH after install"
            N_WARNED=$((N_WARNED + 1))
        fi
    else
        if [ "$sev" = required ]; then
            warn "could not install $probe (the installer's trust gate will re-check)"
        else
            warn "could not install $probe (best-effort — continuing)"
        fi
        N_WARNED=$((N_WARNED + 1))
    fi
}

# ---- REQUIRED group -----------------------------------------------------
# ca-certificates has no command to probe; install it unconditionally (cheap +
# idempotent) only where the manager carries it (apt/dnf/apk; brew ships none).
info "required: minisign unzip curl ca-certificates"
need_tool minisign required minisign
need_tool unzip    required unzip
need_tool curl     required curl
case "$PM" in
    apt|dnf|apk) info "installing ca-certificates"; pm_install ca-certificates && N_INSTALLED=$((N_INSTALLED + 1)) || { warn "ca-certificates install failed (best-effort)"; N_WARNED=$((N_WARNED + 1)); } ;;
esac

# ---- DEFAULT group (edge front: nginx + stream module) ------------------
# Policy: burrowee never installs, enables, or starts nginx without explicit
# operator consent. Present + running -> ok. Otherwise: ask on /dev/tty
# (BURROWEE_NGINX_INSTALL=1/0 pre-answers); yes -> per-PM recipe as root;
# no / no TTY -> print the guidance tips and continue (doctor re-checks).

# nginx_guide <mode> — the operator guidance block. mode=full|service.
nginx_guide() {
    printf '\n  Install it yourself (%s):\n' "$PM" >&2
    if [ "$1" = full ]; then
        case "$PM" in
            apt)  printf '    apt-get update && apt-get install -y nginx libnginx-mod-stream\n' >&2 ;;
            dnf)  printf '    %s install -y nginx\n' "$DNF_BIN" >&2 ;;
            apk)  printf '    apk add nginx nginx-mod-stream\n' >&2 ;;
            brew) printf '    brew install nginx\n' >&2 ;;
        esac
    fi
    case "$PM" in
        apt|dnf) printf '    systemctl enable --now nginx\n' >&2 ;;
        apk)     printf '    rc-update add nginx default && rc-service nginx start\n' >&2 ;;
        brew)    printf '    sudo brew services start nginx      # system daemon, not a user agent\n' >&2 ;;
    esac
    printf '\n  Or ask your AI agent — copy this line:\n' >&2
    printf '    Install nginx with its stream module on this machine, run it as a\n' >&2
    printf '    root/system service, then run: sudo burrowee edge doctor\n\n' >&2
}

# nginx_running — best-effort master probe (pgrep may be absent: treat as running
# so a limited box never double-prompts; doctor owns the authoritative check).
nginx_running() {
    command -v pgrep >/dev/null 2>&1 || return 0
    pgrep -x nginx >/dev/null 2>&1
}

# nginx_consent — env pre-answer, else ask on /dev/tty; no TTY = no.
nginx_consent() {
    case "${BURROWEE_NGINX_INSTALL:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    [ -n "${BURROWEE_PREFLIGHT_NO_TTY:-}" ] && return 1
    [ -r /dev/tty ] && [ -w /dev/tty ] || return 1
    printf '  %s [y/N] ' "$1" > /dev/tty
    IFS= read -r pf_ans < /dev/tty || return 1
    case "$pf_ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

# nginx_install <mode> — the consented recipe, as root. mode=full|service.
nginx_install() {
    if [ "$1" = full ]; then
        case "$PM" in
            apt)
                if [ "$APT_UPDATED" = 0 ]; then run apt-get update; APT_UPDATED=1; fi
                run apt-get install -y nginx libnginx-mod-stream || return 1 ;;
            dnf)
                run "$DNF_BIN" install -y nginx || return 1
                run "$DNF_BIN" install -y nginx-mod-stream >/dev/null 2>&1 || true ;;
            apk)  run apk add nginx nginx-mod-stream || return 1 ;;
            brew)
                # brew refuses root; drop to the sudo-ing user for the install.
                if [ "$(id -u)" = 0 ]; then
                    [ -n "${SUDO_USER:-}" ] || { warn "cannot run brew as root and no SUDO_USER to drop to"; return 1; }
                    run sudo -u "$SUDO_USER" brew install nginx || return 1
                else
                    run brew install nginx || return 1
                fi ;;
        esac
    fi
    case "$PM" in
        apt|dnf) run systemctl enable --now nginx ;;
        apk)     run rc-update add nginx default && run rc-service nginx start ;;
        brew)
            # always a system LaunchDaemon, never a user agent: root runs it
            # directly, a non-root operator re-sudos (consent was just given
            # on the TTY, so an interactive sudo prompt here is fine).
            if [ "$(id -u)" = 0 ]; then
                run brew services start nginx
            else
                run sudo brew services start nginx
            fi ;;
    esac
}

if [ "$NGINX" = 1 ] && [ -z "${BURROWEE_SKIP_NGINX:-}" ]; then
    info "edge front: nginx + stream module (operator-consented)"
    MODE=""
    if ! present nginx; then
        MODE=full
        warn "nginx not found — burrowee edge needs a system-level nginx (stream module included)"
    elif ! nginx_running; then
        MODE=service
        warn "nginx is installed but not running as a service"
    else
        ok "nginx present and running"
        N_SKIPPED=$((N_SKIPPED + 1))
    fi
    if [ -n "$MODE" ]; then
        if [ "$MODE" = full ] && nginx_consent "Install nginx now via $PM (root)?"; then
            if nginx_install full && { [ -n "$DRY" ] || present nginx; }; then
                ok "nginx installed + service enabled"
                N_INSTALLED=$((N_INSTALLED + 1))
            else
                warn "nginx install did not complete"
                nginx_guide full
                N_WARNED=$((N_WARNED + 1))
            fi
        elif [ "$MODE" = service ] && nginx_consent "Enable + start nginx now via $PM (root)?"; then
            if nginx_install service; then
                ok "nginx service enabled + started"
                N_INSTALLED=$((N_INSTALLED + 1))
            else
                warn "could not start nginx"
                nginx_guide service
                N_WARNED=$((N_WARNED + 1))
            fi
        else
            nginx_guide "$MODE"
            N_WARNED=$((N_WARNED + 1))
        fi
    fi
fi

# ---- BEST-EFFORT group --------------------------------------------------
info "best-effort: netcat openssl jq"
case "$PM" in
    apt)  need_tool nc   best netcat-openbsd ;;
    dnf)  need_tool nc   best nmap-ncat ;;
    apk)  need_tool nc   best netcat-openbsd ;;
    brew) need_tool nc   best netcat ;;
esac
need_tool openssl best openssl
need_tool jq      best jq

# ---- summary ------------------------------------------------------------
printf '\n'
ok "preflight done — installed=$N_INSTALLED skipped=$N_SKIPPED warned=$N_WARNED"
exit 0
