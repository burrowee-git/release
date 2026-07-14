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
//     COMPONENT source worktree (release.sh lines 558-560 for relay, 728-734
//     for edge). The burrowee-<comp>-updater runs `sh ./update.sh` /
//     `sh ./updater.update.sh` with cwd = the unzipped bundle, so they must ship
//     alongside the bins.
//   - edge additionally carries covers/admin.html + covers/default.html, decoy
//     cover pages copied from the edge.web repo at package time (release.sh lines
//     736-742): admin.html → covers/admin.html, login.html → covers/default.html.
//     Resolved via EDGE_WEB_DIR, else $BB/edge.web/code/edge.web (release.sh line 738).
//
// All other components (cli/gateway/agent) have no extras.
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
