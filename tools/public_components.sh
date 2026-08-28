#!/usr/bin/env bash
# public_components.sh — the fixed set of components tools/gen-bootstraps.sh
# renders outer bootstraps for: cli, gateway, edge, agent. relay is excluded —
# it uses tools/relay-bootstrap.template.sh (a private, gated channel) and has
# no install.sh/upgrade.sh/beta.*.sh of the public shape.
#
# Sourced by tools/gen-bootstraps.sh (what gets RENDERED, including which
# components' beta.*.sh twins can exist and be SWEPT on a closed cycle) and by
# tools/release.sh (which components' beta.*.sh a stable cut's sweep-staging
# must cover — see the `git add -A --` block in do_release). Same reasoning as
# tools/binmap.sh: this list used to be hardcoded independently at each site,
# and the dangerous direction is a site that forgets one — here, a stable cut's
# sweep-staging that only covers the component being cut leaves ANOTHER
# component's just-closed beta cycle's deletions unstaged, which is exactly the
# wedge this file exists to close by construction rather than by convention.
# shellcheck disable=SC2034  # consumed by every file that sources this one, not by this one itself.
PUBLIC_COMPONENTS="cli gateway edge agent"
