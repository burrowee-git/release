# module: platform-detect  v2
# needs:  helpers
# since:  2026-08-27
case "$(uname -s)" in
    Darwin) OS=darwin ;;
    Linux)  OS=linux ;;
    *)      fail "unsupported OS: $(uname -s) (@brand@ ships darwin + linux only)" ;;
esac
case "$(uname -m)" in
    arm64|aarch64) ARCH=arm64 ;;
    x86_64|amd64)  ARCH=amd64 ;;
    *)             fail "unsupported arch: $(uname -m) (@brand@ ships arm64 + amd64 only)" ;;
esac

# Intel Macs below macOS 12 need the darwin-amd64-legacy artifact (Go >= 1.25
# imports a macOS-12-only Security.framework symbol; the legacy build does not).
# Apple Silicon below 12 is not shipped: refuse with the upgrade path.
if [ "$OS" = darwin ]; then
    _pd_major="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
    case "$_pd_major" in ''|*[!0-9]*) _pd_major=99 ;; esac
    if [ "$_pd_major" -lt 12 ]; then
        case "$ARCH" in
            amd64) ARCH=amd64-legacy ;;
            arm64) fail "macOS $_pd_major on Apple Silicon is not supported — upgrade to macOS 12 or later" ;;
        esac
    fi
fi

printf '\n  @brand@ %s installer  (%s/%s)\n\n' "$COMP" "$OS" "$ARCH"
