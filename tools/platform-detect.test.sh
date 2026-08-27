#!/usr/bin/env bash
# tools/platform-detect.test.sh — eight OS/arch/macOS-version vectors for
# tools/modules/platform-detect.sh, including the darwin-amd64-legacy
# selection added for Intel Macs below macOS 12 (Go >= 1.25's
# Security.framework import needs macOS 12+; see docs/specs/
# 2026-08-27-darwin-legacy-build-design.md §7).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail_count=0; check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail_count=1; fi; }
MOD="$(mktemp)"; trap 'rm -f "$MOD"' EXIT INT TERM
sed -e 's/@brand@/burrowee/g' "${HERE}/modules/platform-detect.sh" > "$MOD"
run() { # run <uname -s> <uname -m> <sw_vers|-> → prints "OS/ARCH" or "FAIL:<msg>"
    ( exec 3>&1  # fd 3 = a copy of this subshell's real stdout, taken BEFORE
                 # the `. "$MOD" >/dev/null 2>&1` below redirects fd1/fd2 for
                 # that one command only. fail() writes through fd 3 so its
                 # message survives that redirect instead of being discarded
                 # by it — otherwise a refusal is indistinguishable from
                 # empty output and this case could never fail.
      COMP=cli
      # shellcheck disable=SC2329
      uname() { case "$1" in -s) printf '%s' "$U_S" ;; -m) printf '%s' "$U_M" ;; esac; }
      if [ "$3" = "-" ]; then sw_vers() { return 127; }; else sw_vers() { printf '%s\n' "$SW"; }; fi
      fail() { printf 'FAIL:%s' "$1" >&3; exit 1; }
      U_S="$1" U_M="$2" SW="$3"; . "$MOD" >/dev/null 2>&1; printf '%s/%s' "$OS" "$ARCH" )
}
check "catalina intel → legacy"   "$(run Darwin x86_64 10.15.8)" "darwin/amd64-legacy"
check "big sur intel → legacy"    "$(run Darwin x86_64 11.7.10)" "darwin/amd64-legacy"
check "monterey intel → stock"    "$(run Darwin x86_64 12.6.1)"  "darwin/amd64"
check "tahoe intel → stock"       "$(run Darwin x86_64 26.0)"    "darwin/amd64"
check "no sw_vers → stock"        "$(run Darwin x86_64 -)"       "darwin/amd64"
check "big sur arm64 → refused"   "$(run Darwin arm64 11.7.10 | cut -c1-5)" "FAIL:"
check "monterey arm64 → stock"    "$(run Darwin arm64 12.0)"     "darwin/arm64"
check "linux untouched"           "$(run Linux x86_64 -)"        "linux/amd64"
exit "$fail_count"
