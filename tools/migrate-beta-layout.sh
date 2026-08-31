#!/usr/bin/env bash
# migrate-beta-layout.sh — ONE-TIME: copy the three pre-existing beta stamps
# from <comp>/<stamp>/ to <comp>/beta/<stamp>/. Delete this script once the
# migration is confirmed; it is not a mode of the retention pass.
#
# Order is not negotiable: copy, then repoint the console rows, then verify,
# then delete. Deleting before repointing takes the artifacts out from under
# any host currently running that beta.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:${HOME}/bin:${PATH}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTER="${REPO_ROOT}/dist/.tools/burrowee-release-register"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

EXECUTE=0
[ "${1:-}" = "--execute" ] && EXECUTE=1

migrate() {
    local comp="$1" stamp="$2"
    echo "=== ${comp} ${stamp} ==="
    local src="${STAGE}/${comp}"
    mkdir -p "${src}"

    if [ "${EXECUTE}" = 1 ]; then
        # Pull the old-layout objects down through the gated console endpoint,
        # which is the only reader with credentials for a private beta.
        echo "→ fetching ${comp}/${stamp}/ …"
        "${REGISTER}" fetch-dir --comp "${comp}" --stamp "${stamp}" --to-dir "${src}"

        "${REGISTER}" publish-dir --comp "${comp}" --channel beta \
            --stamp "${stamp}" --from-dir "${src}"
    else
        # Dry-run means "contacts nothing" — fetch is gated the same as
        # publish-dir, not just echoed after a real network call already ran.
        echo "→ would fetch ${comp}/${stamp}/"
        echo "→ would publish-dir --comp ${comp} --channel beta --stamp ${stamp}"
    fi
}

migrate edge    v0.2.21.beta.2026.08.28.716c7ede
migrate gateway v0.2.17.beta.2026.08.28.acd89694
migrate relay   v0.2.20.beta.2026.08.28.5c285586
