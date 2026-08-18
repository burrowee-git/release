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
// takesSharedLadder reports whether this component's migrations/ is assembled
// from inner/_shared/migrations PLUS its own repo, rather than wholly from its
// own repo. Mirrors takes_shared_ladder in tools/payload.sh.
//
// The gateway is deliberately absent: its runner lives in the gateway repo, has
// shipped, and does three things no other component needs — stopping a daemon
// so a SQLite store is at rest while it is copied, pre-flighting the cli's
// `migrate` verb, and resolving which ACCOUNT's pre-split tree holds the host's
// identity.
func takesSharedLadder(comp string) bool {
	return comp == "edge" || comp == "cli"
}

// sharedMigrationScripts returns the shared ladder's files under
// <repoDir>/inner/_shared/migrations, sorted by basename. Discovered by glob
// rather than listed, so adding one stays a one-file change; mirrors
// shared_migration_scripts in tools/payload.sh.
func sharedMigrationScripts(repoDir string) ([]string, error) {
	dir := filepath.Join(repoDir, "inner", "_shared", "migrations")
	paths, err := filepath.Glob(filepath.Join(dir, "*.sh"))
	if err != nil {
		return nil, fmt.Errorf("shared migrations glob %s: %w", dir, err)
	}
	sort.Strings(paths)
	return paths, nil
}

// componentMigrationFiles returns the component's OWN half of its ladder —
// component.conf, ledger, and any rung it authored — sorted by basename.
// Mirrors component_migration_files in tools/payload.sh.
func componentMigrationFiles(srcDir string) ([]string, error) {
	paths, err := filepath.Glob(filepath.Join(srcDir, "migrations", "*"))
	if err != nil {
		return nil, fmt.Errorf("component migrations glob %s: %w", srcDir, err)
	}
	var files []string
	for _, p := range paths {
		if st, statErr := os.Stat(p); statErr != nil || st.IsDir() {
			continue
		}
		files = append(files, p)
	}
	sort.Strings(files)
	return files, nil
}

// ledgerFileMigrations returns the script names a migrations/ledger data file
// declares, in ledger order.
//
// The shared runner reads its ledger from a FILE rather than from a here-string
// inside itself, because one runner is copied byte-identical into several kits
// and a per-component list cannot live inside it. Word-split into (version,
// script) pairs EXACTLY as that runner splits it, so the two cannot disagree
// about what a ledger says. An odd word count is an error rather than a
// truncation: a dangling word is a row with a target and no script (or the
// reverse), the runner refuses on it, and a cut that shipped one would refuse
// on every host. Mirrors ledger_file_migrations in tools/payload.sh.
func ledgerFileMigrations(body string) ([]string, error) {
	var words []string
	for _, line := range strings.Split(body, "\n") {
		if i := strings.Index(line, "#"); i >= 0 {
			line = line[:i]
		}
		words = append(words, strings.Fields(line)...)
	}
	if len(words) == 0 || len(words)%2 != 0 {
		return nil, fmt.Errorf("ledger holds %d words, want (version, script) pairs", len(words))
	}
	scripts := make([]string, 0, len(words)/2)
	for i := 1; i < len(words); i += 2 {
		scripts = append(scripts, words[i])
	}
	return scripts, nil
}

// sharedLadderPayload returns the migrations/ members for a component assembled
// from two sources, in the order tools/payload.sh emits them: the shared files
// first, then the component's own.
//
// component.conf and ledger are REQUIRED. The shared runner carries no
// component defaults and refuses without them, so a kit missing either is a
// component whose EVERY install ends in a refusal — caught here, at the cut,
// rather than on a host. run.sh, lib_paths.sh and lib_stale_user_bins.sh are
// required for the same reason one level up: install.sh sources the sweep from
// this directory and runs the ladder out of it, and a zip missing any of them
// installs cleanly and silently stops migrating.
func sharedLadderPayload(comp, srcDir, repoDir string) ([]pack.Content, error) {
	shared, err := sharedMigrationScripts(repoDir)
	if err != nil {
		return nil, err
	}
	own, err := componentMigrationFiles(srcDir)
	if err != nil {
		return nil, err
	}
	var extras []pack.Content
	present := map[string]bool{}
	for _, p := range append(append([]string{}, shared...), own...) {
		base := filepath.Base(p)
		present[base] = true
		// Zip member names are always "/"-separated; filepath.Join would be
		// wrong the moment this is built anywhere non-unix.
		extras = append(extras, pack.Content{Src: p, Name: "migrations/" + base})
	}
	// upgrade.sh is required because the HOSTED release.burrowee.com/<comp>/upgrade.sh
	// one-liner execs it out of this same kit and refuses at runtime when it is
	// absent — a rendered bootstrap whose kit cannot answer it is a URL that
	// exists and does not work.
	for _, want := range []string{"run.sh", "upgrade.sh", "lib_paths.sh", "lib_stale_user_bins.sh"} {
		if !present[want] {
			return nil, fmt.Errorf("shared migration %s missing under %s", want,
				filepath.Join(repoDir, "inner", "_shared", "migrations"))
		}
	}
	for _, want := range []string{"component.conf", "ledger"} {
		if !present[want] {
			return nil, fmt.Errorf("%s migrations/%s missing in source %s", comp, want,
				filepath.Join(srcDir, "migrations"))
		}
	}
	// The globs ship whatever is on disk; the LEDGER is what the runner will
	// actually walk. A rung named in it but never committed is a row the runner
	// refuses on — on every host, after the cut — so the build is the last place
	// it can be caught.
	ledgerPath := filepath.Join(srcDir, "migrations", "ledger")
	body, err := os.ReadFile(ledgerPath)
	if err != nil {
		return nil, fmt.Errorf("read %s migration ledger %s: %w", comp, ledgerPath, err)
	}
	named, err := ledgerFileMigrations(string(body))
	if err != nil {
		return nil, fmt.Errorf("%s migration ledger in %s: %w", comp, ledgerPath, err)
	}
	for _, name := range named {
		if !present[name] {
			return nil, fmt.Errorf("%s migration %q is named in the ledger of %s but no such file was staged", comp, name, ledgerPath)
		}
	}
	return extras, nil
}

func extraPayload(comp, srcDir, repoDir string) ([]pack.Content, error) {
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
	// LAST, matching payload_manifest's emission order in tools/payload.sh —
	// cmd/rkit/payload_manifest_test.go compares the two lists name-for-name, so
	// an order that differed would be a red test rather than a real defect.
	if takesSharedLadder(comp) {
		shared, err := sharedLadderPayload(comp, srcDir, repoDir)
		if err != nil {
			return nil, err
		}
		extras = append(extras, shared...)
	}
	return extras, nil
}
