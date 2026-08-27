#!/usr/bin/env bash
# tools/prune-releases.test.sh — channel-filtered retention (spec §5.5): a
# stable prune must never count or delete a beta tag, and vice versa. Stubs
# `ghp` on PATH (the script never has real network/GitHub access here) so the
# delete list can be asserted directly from DRY-RUN output.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
check_contains() { case "$2" in *"$3"*) echo "ok: $1";; *) echo "FAIL: $1 — missing '$3' in: $2"; fail=1;; esac; }
check_not_contains() { case "$2" in *"$3"*) echo "FAIL: $1 — unwanted '$3' in: $2"; fail=1;; *) echo "ok: $1";; esac; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
STUB="${WORK}/stub"; mkdir -p "${STUB}"
cat > "${STUB}/ghp" <<'EOF'
#!/usr/bin/env bash
# Fake ghp: "api ... releases" prints the fixed tag fixture; anything else no-ops.
case "$1" in
  api) cat "${GHP_STUB_TAGS}" ;;
  *)   exit 0 ;;
esac
EOF
chmod +x "${STUB}/ghp"

cat > "${WORK}/tags" <<'EOF'
cli/v0.1.1.2026.06.01.aaaaaaaa
cli/v0.1.2.2026.06.02.bbbbbbbb
cli/v0.1.3.2026.06.03.cccccccc
cli/v0.1.4.2026.06.04.dddddddd
cli/v0.2.1.beta.2026.07.01.eeeeeeee
cli/v0.2.2.beta.2026.07.02.ffffffff
cli/v0.2.3.beta.2026.07.03.11111111
EOF

run() { CHANNEL="$1" KEEP="$2" COMPONENTS=cli PATH="${STUB}:${PATH}" GHP_STUB_TAGS="${WORK}/tags" \
  bash "${HERE}/prune-releases.sh"; }

out_stable="$(run stable 2)"
check_contains  "stable drops the 2 oldest stable tags" "${out_stable}" "would delete cli/v0.1.1"
check_contains  "stable drops the 2 oldest stable tags (2nd)" "${out_stable}" "would delete cli/v0.1.2"
check_not_contains "stable keeps v0.1.3/v0.1.4" "${out_stable}" "would delete cli/v0.1.3"
check_not_contains "stable never lists a beta tag" "${out_stable}" "beta"

out_beta="$(run beta 2)"
check_contains  "beta drops the oldest beta tag" "${out_beta}" "would delete cli/v0.2.1.beta"
check_not_contains "beta keeps v0.2.2/v0.2.3" "${out_beta}" "would delete cli/v0.2.2"
check_not_contains "beta never lists a stable tag" "${out_beta}" "would delete cli/v0.1."

exit "${fail}"
