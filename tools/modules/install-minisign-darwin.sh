# module: install-minisign-darwin  v1
# needs:  helpers platform-detect install-minisign-common
# since:  2026-08-26
# macOS: Homebrew first when it is there (as this user, never via sudo), then
# the pinned upstream build — which upstream ships for arm64 only, so an Intel
# Mac without Homebrew gets a plain statement of the gap and require-minisign's
# brew recipe. A Homebrew minisign that a daemon-hosted shell's bare PATH cannot
# see is still an install: the known locations count as present.
_md_have=""
for _md_p in $MINISIGN_KNOWN_PATHS; do [ -x "$_md_p" ] && _md_have=1; done
if [ "$OS" = darwin ] && [ -z "$_md_have" ] && ! command -v minisign >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        info "minisign: not found — trying Homebrew"
        brew install minisign >/dev/null 2>&1 || true
        for _md_p in $MINISIGN_KNOWN_PATHS; do [ -x "$_md_p" ] && _md_have=1; done
    fi
    if [ -n "$_md_have" ] || command -v minisign >/dev/null 2>&1; then
        ok "minisign installed by Homebrew"
    elif [ "$ARCH" = arm64 ]; then
        info "minisign: trying the pinned upstream build"
        _md_asset="minisign-$MINISIGN_VERSION-macos.zip"
        if minisign_fetch "$_md_asset" "$MINISIGN_MACOS_SHA256" \
           && unzip -oq "$TMP/$_md_asset" minisign -d "$TMP/minisign-macos" 2>/dev/null \
           && _md_bin="$(minisign_install_file "$TMP/minisign-macos/minisign")" \
           && minisign_seal "$TMP/$_md_asset" "$_md_bin"; then
            MINISIGN="$_md_bin"
            ok "minisign $MINISIGN_VERSION installed to $(dirname "$_md_bin") (pinned upstream build)"
        else
            info "minisign: could not install the pinned upstream build (network, mirrors, or its signature)"
        fi
    else
        info "minisign: upstream ships no Intel build — install Homebrew, then minisign"
    fi
fi
