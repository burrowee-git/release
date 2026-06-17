#!/usr/bin/env bash
# prune_keep.test.sh — unit test for tools/prune_releases_keep.sh keep_latest.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/prune_releases_keep.sh
. "${HERE}/prune_releases_keep.sh"

# 5 stamps: version-sorted the 2 oldest should be selected for deletion
STAMPS="v0.1.1.2026.06.01.aabbccdd v0.1.2.2026.06.02.bbccddee v0.1.3.2026.06.03.ccddeeff v0.1.4.2026.06.04.ddeeffaa v0.1.5.2026.06.05.eeffaabb"

# shellcheck disable=SC2086  # intentional word-split of STAMPS
result="$(keep_latest 3 $STAMPS)"

expected="$(printf '%s\n' 'v0.1.1.2026.06.01.aabbccdd' 'v0.1.2.2026.06.02.bbccddee')"

if [ "${result}" != "${expected}" ]; then
    echo "FAIL: expected:"
    printf '%s\n' "${expected}"
    echo "got:"
    printf '%s\n' "${result}"
    exit 1
fi

# also test: exactly N stamps → nothing deleted
# shellcheck disable=SC2086
result2="$(keep_latest 3 v0.1.1.2026.06.01.aabbccdd v0.1.2.2026.06.02.bbccddee v0.1.3.2026.06.03.ccddeeff)"
if [ -n "${result2}" ]; then
    echo "FAIL: expected empty output for exactly-N stamps, got: ${result2}"
    exit 1
fi

echo "ALL OK"
