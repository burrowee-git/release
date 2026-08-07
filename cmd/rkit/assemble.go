package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

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

// ledgerMigrations returns the migration script names named in the runner's
// MIGRATIONS= ledger, in ledger order.
//
// The ledger is a shell here-string of "<version-this-upgrades-to> <script>"
// rows, oldest first:
//
//	MIGRATIONS="
//	0.2.0 v1_to_v2.sh
//	"
//
// Parsed the same way the runner parses it — word-split into (version, script)
// pairs — so the two cannot disagree about what the ledger says. Only an
// assignment at column 0 counts, which is where the runner writes it and where
// a commented-out copy never is.
func ledgerMigrations(runSh string) ([]string, error) {
	const key = `MIGRATIONS="`
	lines := strings.Split(runSh, "\n")
	start := -1
	for i, line := range lines {
		if !strings.HasPrefix(line, key) {
			continue
		}
		if start >= 0 {
			return nil, fmt.Errorf(`more than one MIGRATIONS=" assignment`)
		}
		start = i
	}
	if start < 0 {
		return nil, fmt.Errorf(`no MIGRATIONS=" assignment found — this is not the migration runner`)
	}
	rest := strings.Join(append([]string{strings.TrimPrefix(lines[start], key)}, lines[start+1:]...), "\n")
	end := strings.Index(rest, `"`)
	if end < 0 {
		return nil, fmt.Errorf(`unterminated MIGRATIONS=" assignment`)
	}
	fields := strings.Fields(rest[:end])
	if len(fields)%2 != 0 {
		return nil, fmt.Errorf("ledger holds %d words, want (version, script) pairs", len(fields))
	}
	scripts := make([]string, 0, len(fields)/2)
	for i := 1; i < len(fields); i += 2 {
		scripts = append(scripts, fields[i])
	}
	return scripts, nil
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
//   - gateway additionally carries the whole migrations/ dir (run.sh + every
//     migration in its ledger), invoked by install.sh and update.sh from the unzipped dir.
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
		// The whole migrations/ dir rides along: migrations/run.sh is the runner
		// install.sh and update.sh invoke, and it needs every migration named in
		// its ledger present, because a host may be upgrading across several
		// releases at once. Discovered by glob rather than listed here, so adding a
		// migration stays a gateway-repo change — a hardcoded list would silently
		// ship a runner whose ledger names a script that is not in the zip.
		//
		// run.sh is REQUIRED: a gateway zip without it turns every upgrade that
		// needs a migration into a daemon that comes back without its state, which
		// is far worse than a build that stops here.
		mig := filepath.Join(srcDir, "migrations")
		scripts, globErr := filepath.Glob(filepath.Join(mig, "*.sh"))
		if globErr != nil {
			return nil, fmt.Errorf("gateway migrations glob %s: %w", mig, globErr)
		}
		sort.Strings(scripts)
		shipped := map[string]bool{}
		for _, p := range scripts {
			base := filepath.Base(p)
			shipped[base] = true
			// Zip member names are always "/"-separated; filepath.Join would be
			// wrong the moment this is built anywhere non-unix.
			extras = append(extras, pack.Content{Src: p, Name: "migrations/" + base})
		}
		runner := filepath.Join(mig, "run.sh")
		if !shipped["run.sh"] {
			return nil, fmt.Errorf("gateway migration runner missing in source %s", runner)
		}
		// The glob ships whatever is on disk; the LEDGER is what the runner will
		// actually walk. A migration added to MIGRATIONS= but never committed as
		// a file is a row the runner warns about and skips — after which the
		// caller records the version and that rung is gated off on every host,
		// permanently. Nothing downstream can recover it, so the build is the
		// last place it can be caught.
		body, readErr := os.ReadFile(runner)
		if readErr != nil {
			return nil, fmt.Errorf("read gateway migration runner %s: %w", runner, readErr)
		}
		named, ledgerErr := ledgerMigrations(string(body))
		if ledgerErr != nil {
			return nil, fmt.Errorf("gateway migration ledger in %s: %w", runner, ledgerErr)
		}
		for _, name := range named {
			if !shipped[name] {
				return nil, fmt.Errorf("gateway migration %q is named in the ledger of %s but no such file exists in %s", name, runner, mig)
			}
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
