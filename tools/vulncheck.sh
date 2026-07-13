#!/usr/bin/env bash
# vulncheck.sh — release-time CVE gate helpers, sourced by tools/release.sh.
# Kept self-contained so a future shared release flow can lift it unchanged.

# resolve_release_mode <apple> <vulncheck> <answer>
# Folds the interactive prompt answer into the final signing/scan modes and
# prints "<apple>|<vulncheck>" (each "1" or empty). A y/Y answer forces both on.
resolve_release_mode() {
    local apple="$1" vuln="$2" ans="$3"
    case "${ans}" in [yY]*) apple=1; vuln=1 ;; esac
    printf '%s|%s' "${apple}" "${vuln}"
}
