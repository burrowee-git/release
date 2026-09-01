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
//	0.2.0 v0_1_to_v0_2.sh
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
//     Resolved via EDGE_WEB_DIR, else $BB/edge.web/code/main (release.sh line 1064).
//   - edge + gateway carry updater.install.sh, copied from THIS repo's own
//     inner/<comp>/ (not the component source worktree) if it exists there —
//     see updaterInstallPayload. cli's updater is a one-shot binary with no
//     service, and agent has no updater installer, so neither carries one.
//   - gateway additionally carries guard.sh, copied the same way from THIS
//     repo's own inner/gateway/ — see guardInstallPayload. Nothing else
//     carries one today: gateway is the only component whose install can stop
//     the daemon serving the operator's own tunnelled session.
//
// The remaining component (agent) has no extras.
// takesSharedLadder reports whether this component's migrations/ is assembled
// from inner/_shared/migrations PLUS its own repo, rather than wholly from its
// own repo. Mirrors takes_shared_ladder in tools/payload.sh.
//
// relay joined for its 0.2.2 root-only collapse: its repo contributes
// component.conf, ledger and adopt_unit_home_tree.sh (the unit-derived source
// selection), and everything else — the runner, the sweep, the shared adoption
// rung its own rung delegates to — is staged from inner/_shared exactly as for
// edge and cli.
//
// The gateway is deliberately absent: its runner lives in the gateway repo, has
// shipped, and does three things no other component needs — stopping a daemon
// so a SQLite store is at rest while it is copied, pre-flighting the cli's
// `migrate` verb, and resolving which ACCOUNT's pre-split tree holds the host's
// identity.
func takesSharedLadder(comp string) bool {
	return comp == "edge" || comp == "cli" || comp == "relay"
}

// sharedMigrationScripts returns the shared ladder's files under
// <repoDir>/inner/_shared/migrations, sorted by basename. Discovered by glob
// rather than listed, so adding one stays a one-file change; mirrors
// shared_migration_scripts in tools/payload.sh.
//
// TEST SUITES ARE NOT PAYLOAD. The glob ships whatever is in the directory, and
// a suite written beside its subject put 25 KB of test harness, chmod 0755, into
// every edge, cli and relay zip. Suites belong in tools/<name>.test.sh — which
// is where every other shell suite in this repo lives — and this exclusion is
// the second lock on that door. tools/payload.sh drops the same two patterns.
func sharedMigrationScripts(repoDir string) ([]string, error) {
	dir := filepath.Join(repoDir, "inner", "_shared", "migrations")
	paths, err := filepath.Glob(filepath.Join(dir, "*.sh"))
	if err != nil {
		return nil, fmt.Errorf("shared migrations glob %s: %w", dir, err)
	}
	kept := paths[:0:0]
	for _, p := range paths {
		if isShellTestFile(filepath.Base(p)) {
			continue
		}
		kept = append(kept, p)
	}
	sort.Strings(kept)
	return kept, nil
}

// isShellTestFile reports whether a basename names a shell test suite rather
// than something a host runs. Mirrors the case pattern in tools/payload.sh's
// shared_migration_scripts.
func isShellTestFile(base string) bool {
	return strings.HasSuffix(base, ".test.sh") || strings.HasSuffix(base, "_test.sh")
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
	required := []string{"run.sh", "upgrade.sh", "lib_paths.sh", "lib_stale_user_bins.sh"}
	if comp == "relay" {
		// relay's own rung (adopt_unit_home_tree.sh, ledger-named and so covered
		// by the ledger check below) derives the adoption SOURCE and then
		// DELEGATES to the shared adopt_user_tree.sh — a dependency no ledger
		// row names, exactly like the sweep library above. A relay kit without
		// it refuses on every pre-collapse host, after the cut.
		required = append(required, "adopt_user_tree.sh")
	}
	for _, want := range required {
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

// updaterInstallPayload returns the updater.install.sh member for this
// component — inner/<comp>/updater.install.sh, if it exists in the release
// repo — or nil.
//
// Present for edge and gateway only: cli's updater is a one-shot binary with
// no service to reinstall, and agent has no updater installer at all. FILE
// PRESENCE is the guard, not a hardcoded component allowlist — exactly like
// preflight.sh's `[ -f … ]` guard in tools/release.sh's outer bootstrap
// staging, and unlike install.sh's per-component, unconditionally REQUIRED
// resolution one level up in build.go. A component that never grows the file
// is simply unaffected; nothing here needs to change to add or drop one.
// Mirrors updater_install_src in tools/payload.sh.
//
// THE EXEC BIT IS FORCED, exactly like install.sh (copyExecutable, below in
// build.go): release-kit's pack.Content carries no mode field, and pack.Zip
// preserves whatever os.Stat reports on Content.Src verbatim — it forces
// nothing. inner/gateway/updater.install.sh is committed as 0644, same as
// every other inner/ script; left unforced, `rkit build` — the produce half
// of every cut (tools/release.sh) — would ship a gateway recovery script an
// operator cannot execute. Copied to a temp file at 0755 rather than mutating
// the checked-in source in place, same shape as install.sh's own copy.
func updaterInstallPayload(comp, repoDir string) (*pack.Content, error) {
	p := filepath.Join(repoDir, "inner", comp, "updater.install.sh")
	if _, err := os.Stat(p); err != nil {
		return nil, nil
	}
	dir, err := os.MkdirTemp("", "rkit-updater-install-*")
	if err != nil {
		return nil, fmt.Errorf("updater.install.sh temp dir: %w", err)
	}
	dst := filepath.Join(dir, "updater.install.sh")
	if err := copyExecutable(p, dst); err != nil {
		return nil, fmt.Errorf("updater.install.sh: %w", err)
	}
	return &pack.Content{Src: dst, Name: "updater.install.sh"}, nil
}

// guardInstallPayload returns the guard.sh member for this component —
// inner/<comp>/guard.sh, if it exists in the release repo — or nil.
//
// Present for gateway only today: gateway is the first component whose
// install can stop the very daemon carrying the operator's own session (a
// migration rung, then the restart itself), so it is the first that needs a
// process handed to launchd/systemd — outliving that session — to finish or
// undo the install. FILE PRESENCE is the guard, not a hardcoded component
// allowlist, exactly like updaterInstallPayload right above. Mirrors
// guard_install_src in tools/payload.sh.
//
// THE EXEC BIT IS FORCED, same reasoning as updaterInstallPayload:
// inner/gateway/guard.sh is committed as 0644 like every other inner/
// script, and pack.Zip preserves whatever os.Stat reports on Content.Src
// verbatim — left unforced, `rkit build` would ship a guard an operator's
// launchd/systemd unit cannot execute.
func guardInstallPayload(comp, repoDir string) (*pack.Content, error) {
	p := filepath.Join(repoDir, "inner", comp, "guard.sh")
	if _, err := os.Stat(p); err != nil {
		return nil, nil
	}
	dir, err := os.MkdirTemp("", "rkit-guard-install-*")
	if err != nil {
		return nil, fmt.Errorf("guard.sh temp dir: %w", err)
	}
	dst := filepath.Join(dir, "guard.sh")
	if err := copyExecutable(p, dst); err != nil {
		return nil, fmt.Errorf("guard.sh: %w", err)
	}
	return &pack.Content{Src: dst, Name: "guard.sh"}, nil
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
	// updater.install.sh comes from THIS repo's inner/<comp>/, like install.sh
	// one level up in build.go — not from srcDir like the members staged just
	// above — so it is resolved separately here rather than folded into the
	// switch. See updaterInstallPayload for the presence guard.
	if ui, err := updaterInstallPayload(comp, repoDir); err != nil {
		return nil, err
	} else if ui != nil {
		extras = append(extras, *ui)
	}
	// guard.sh: same provenance and same presence guard as updater.install.sh
	// right above — see guardInstallPayload. Appended right after it so the
	// assembly order matches tools/payload.sh's payload_manifest.
	if gi, err := guardInstallPayload(comp, repoDir); err != nil {
		return nil, err
	} else if gi != nil {
		extras = append(extras, *gi)
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
		//
		// EVERY FILE, NOT EVERY *.sh. tools/payload.sh globs migrations/* here
		// and this side globbed migrations/*.sh, which is invisible only for as
		// long as the gateway's migrations/ holds nothing but scripts — the day
		// it grows a ledger data file or a component.conf, the shell path ships
		// it and this one does not, and the two zips differ. Both sides carry a
		// "mirrors X in Y" comment; that is not a mechanism, so
		// cmd/rkit/payload_manifest_test.go's gateway fixture now carries a
		// non-.sh member to make this a red test rather than a comment.
		mig := filepath.Join(srcDir, "migrations")
		globbed, globErr := filepath.Glob(filepath.Join(mig, "*"))
		if globErr != nil {
			return nil, fmt.Errorf("gateway migrations glob %s: %w", mig, globErr)
		}
		var scripts []string
		for _, p := range globbed {
			// Directories are not payload members, and tools/payload.sh's
			// `[ -f "${p}" ] || continue` skips them the same way.
			if st, statErr := os.Stat(p); statErr != nil || st.IsDir() {
				continue
			}
			scripts = append(scripts, p)
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
