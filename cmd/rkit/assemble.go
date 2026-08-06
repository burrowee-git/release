package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/burrowee-git/release-kit/build"
	"github.com/burrowee-git/release-kit/pack"
)

// assemble builds one flat zip per target: component bins + dispatcher +
// install.sh + component extras (update scripts, edge covers). Zips land at
// outRoot/stamp/burrowee-<comp>-<os>-<arch>.zip and are returned in
// sorted-target order. extras are target-independent — the same script/cover
// files ride in every platform zip, exactly as tools/release.sh copies them.
func assemble(comp, stamp, outRoot, installSh string, extras []pack.Content, compArts, dispArts []build.Artifact) ([]string, error) {
	byTarget := map[string][]pack.Content{}
	for _, a := range compArts {
		k := a.OS + "-" + a.Arch
		byTarget[k] = append(byTarget[k], pack.Content{Src: a.Path})
	}
	for _, a := range dispArts {
		k := a.OS + "-" + a.Arch
		byTarget[k] = append(byTarget[k], pack.Content{Src: a.Path}) // basename "burrowee"
	}

	targets := make([]string, 0, len(byTarget))
	for k := range byTarget {
		targets = append(targets, k)
	}
	sort.Strings(targets)

	zipDir := filepath.Join(outRoot, stamp)
	if err := os.MkdirAll(zipDir, 0o755); err != nil {
		return nil, fmt.Errorf("assemble %s: %w", comp, err)
	}

	var zips []string
	for _, k := range targets {
		contents := append(byTarget[k], pack.Content{Src: installSh, Name: "install.sh"})
		contents = append(contents, extras...)
		zp := filepath.Join(zipDir, fmt.Sprintf("burrowee-%s-%s.zip", comp, k))
		if err := pack.Zip(pack.Spec{Out: zp, Contents: contents}); err != nil {
			return nil, fmt.Errorf("assemble %s: zip %s: %w", comp, k, err)
		}
		zips = append(zips, zp)
	}
	return zips, nil
}

// extraPayload returns the component-specific files that ride in the zip beyond
// bins + dispatcher + install.sh, mirroring tools/release.sh's per-component
// assembly exactly:
//
//   - edge + relay carry update.sh + updater.update.sh, copied from the
//     COMPONENT source worktree (release.sh lines 1054-1060). The
//     burrowee-<comp>-updater runs `sh ./update.sh` (service update) /
//     `sh ./updater.update.sh` (updater self-update) with cwd = the unzipped
//     bundle, so both must ship alongside the bins.
//   - gateway additionally carries migrations/v1_to_v2.sh, the 0.1.x → 0.2.x config
//     migration invoked by both install.sh and update.sh from the unzipped dir.
//   - gateway + cli carry update.sh ONLY. Core's Phase-0 routing execs the
//     bundled ./update.sh for a non-force `update`, so it must ship. They do
//     NOT carry updater.update.sh: their updater self-updates via an in-process
//     binary swap (UpgradeSelf/ApplyUpdaterBinary), not a shell script, so no
//     such file exists in their source (release.sh lines 1054-1060).
//   - edge additionally carries covers/admin.html + covers/default.html, decoy
//     cover pages copied from the edge.web repo at package time (release.sh lines
//     1063-1068): admin.html → covers/admin.html, login.html → covers/default.html.
//     Resolved via EDGE_WEB_DIR, else $BB/edge.web/code/edge.web (release.sh line 1064).
//
// The remaining component (agent) has no extras.
func extraPayload(comp, srcDir string) ([]pack.Content, error) {
	var extras []pack.Content
	switch comp {
	case "edge", "relay":
		for _, s := range []string{"update.sh", "updater.update.sh"} {
			p := filepath.Join(srcDir, s)
			if _, err := os.Stat(p); err != nil {
				return nil, fmt.Errorf("%s update script missing in source %s: %w", comp, p, err)
			}
			extras = append(extras, pack.Content{Src: p, Name: s})
		}
	case "gateway", "cli":
		s := "update.sh"
		p := filepath.Join(srcDir, s)
		if _, err := os.Stat(p); err != nil {
			return nil, fmt.Errorf("%s update script missing in source %s: %w", comp, p, err)
		}
		extras = append(extras, pack.Content{Src: p, Name: s})
	}
	if comp == "gateway" {
		// migrations/v1_to_v2.sh performs the 0.1.x → 0.2.x config migration (0.2.0 moved the
		// gateway's config and state into SYSTEM roots, with the daemon running as
		// root). Both install.sh and update.sh invoke it from the unzipped release
		// dir, so it has to be IN the zip — and REQUIRED, not best-effort: a
		// gateway zip without it turns every 0.1.x upgrade into a daemon that comes
		// back without its identity, which is worse than a build that fails here.
		// The zip entry name is a literal forward-slash path (like covers/ above):
		// archive members are always "/"-separated, so filepath.Join would be
		// wrong the moment this is built anywhere non-unix.
		p := filepath.Join(srcDir, "migrations", "v1_to_v2.sh")
		if _, err := os.Stat(p); err != nil {
			return nil, fmt.Errorf("gateway migration script missing in source %s: %w", p, err)
		}
		extras = append(extras, pack.Content{Src: p, Name: "migrations/v1_to_v2.sh"})
	}
	if comp == "edge" {
		edgeWeb := os.Getenv("EDGE_WEB_DIR")
		if edgeWeb == "" {
			bb := os.Getenv("BB")
			if bb == "" {
				bb = defaultBB
			}
			edgeWeb = filepath.Join(bb, "edge.web", "code", "edge.web")
		}
		extras = append(extras,
			pack.Content{Src: filepath.Join(edgeWeb, "admin.html"), Name: "covers/admin.html"},
			pack.Content{Src: filepath.Join(edgeWeb, "login.html"), Name: "covers/default.html"},
		)
	}
	return extras, nil
}
