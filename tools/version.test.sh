#!/usr/bin/env bash
# tools/version.test.sh — version.sh channel behaviour.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi; }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/repo/versions" "${WORK}/repo/tools" "${WORK}/src"
cp "${HERE}/version.sh" "${WORK}/repo/tools/version.sh"
( cd "${WORK}/repo" && git init -q && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed )
( cd "${WORK}/src" && git init -q && echo x > f && git add f && git -c user.name=t -c user.email=t@t commit -q -m seed )
SHA="$(git -C "${WORK}/src" rev-parse --short=8 HEAD)"
printf '0.2.8\n' > "${WORK}/repo/versions/cli"
V="${WORK}/repo/tools/version.sh"

check "stable semver unchanged" "$(bash "$V" cli --semver)" "0.2.8"
bash "$V" cli --channel beta --semver >/dev/null 2>&1; check "beta semver refuses when versions/cli.beta absent" "$?" "1"
printf '0.3.0\n' > "${WORK}/repo/versions/cli.beta"
check "beta semver" "$(bash "$V" cli --channel beta --semver)" "0.3.0"
check "beta stamp shape" "$(SRC_DIR="${WORK}/src" bash "$V" cli --channel beta --stamp)" "v0.3.0.beta.$(date -u +%Y.%m.%d).${SHA}"
check "stable stamp has no beta segment" "$(SRC_DIR="${WORK}/src" bash "$V" cli --stamp)" "v0.2.8.$(date -u +%Y.%m.%d).${SHA}"
check "beta bump-patch" "$(bash "$V" cli --channel beta --bump-patch)" "0.3.1"
check "stable file untouched by beta bump" "$(cat "${WORK}/repo/versions/cli")" "0.2.8"
bash "$V" cli --channel beta --assert-beta-above-stable >/dev/null 2>&1; check "0.3.1 > 0.2.8 passes" "$?" "0"
printf '0.2.8\n' > "${WORK}/repo/versions/cli.beta"
bash "$V" cli --channel beta --assert-beta-above-stable >/dev/null 2>&1; check "equal refused" "$?" "1"
printf '0.2.7\n' > "${WORK}/repo/versions/cli.beta"
bash "$V" cli --channel beta --assert-beta-above-stable >/dev/null 2>&1; check "lower refused" "$?" "1"
exit "${fail}"
