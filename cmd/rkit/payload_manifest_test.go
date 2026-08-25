package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// The two assembly paths.
//
// A component zip is assembled by tools/release.sh (the path every cut to date
// has used) AND by cmd/rkit/assemble.go's extraPayload (the path `rkit build`
// uses). They agreed by comment and by nothing else, and gateway
// v0.2.0.2026.08.07 shipped signed, notarized and published with no migrations/
// in it: extraPayload staged the directory, release.sh's `zip -j` dropped it,
// and no check compared the two.
//
// Factoring the manifest into one implementation both consume is not possible
// here — one side is bash running on the operator's machine, the other is Go
// compiled into rkit, and neither can call the other during a cut without
// making the shell path depend on a built binary it currently does not need.
// So the manifest is stated once per language and PINNED TO EACH OTHER by this
// test: tools/payload.sh's payload_manifest is executed for real and its output
// compared name-for-name against extraPayload's. Either side gaining, losing or
// renaming a payload member without the other turns this red.
//
// This is deliberately a manifest comparison, not a byte comparison. The full
// artifact diff already exists as `rkit harness --component <comp>`, which
// builds both sides for real and diffs every zip entry (cmd/rkit/harness.go);
// it needs a toolchain, four cross-compiles and a test signing key, so it is
// not something a plain `go test ./...` can run. This test is the cheap,
// hermetic half that runs on every commit and catches the whole class of defect
// that actually occurred: divergent FILE SETS.

// shellManifest runs tools/payload.sh's payload_manifest for a component and
// returns the member names it prints.
func shellManifest(t *testing.T, comp, srcDir string) []string {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	payloadSh := filepath.Join(repoRoot, "tools", "payload.sh")
	if _, err := os.Stat(payloadSh); err != nil {
		t.Fatalf("tools/payload.sh not found: %v", err)
	}
	cmd := exec.Command("bash", "-c",
		`set -euo pipefail; source "$1"; payload_manifest "$2" "$3"`,
		"bash", payloadSh, comp, srcDir)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("payload_manifest %s: %v\n%s", comp, err, out)
	}
	var names []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line != "" {
			names = append(names, line)
		}
	}
	sort.Strings(names)
	return names
}

// Both manifests resolve the SHARED ladder (inner/_shared/migrations) out of
// repoRoot (trusted_comment_test.go), so the two sides are compared against the
// same real directory rather than against two fixtures that could agree while
// the shipped set differed from both.

// goManifest returns extraPayload's member names for a component.
func goManifest(t *testing.T, comp, srcDir string) []string {
	t.Helper()
	extras, err := extraPayload(comp, srcDir, repoRoot(t))
	if err != nil {
		t.Fatalf("extraPayload %s: %v", comp, err)
	}
	var names []string
	for _, c := range extras {
		names = append(names, c.Name)
	}
	sort.Strings(names)
	return names
}

// srcFixture writes a component source tree holding the given files (relative
// paths, "/"-separated) and returns its root.
func srcFixture(t *testing.T, files ...string) string {
	t.Helper()
	dir := t.TempDir()
	for _, f := range files {
		p := filepath.Join(dir, filepath.FromSlash(f))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// ledgerRunner overwrites migrations/run.sh with a runner whose MIGRATIONS=
// ledger names exactly these scripts — extraPayload rejects a runner it cannot
// parse, so a placeholder file will not do.
func ledgerRunner(t *testing.T, dir string, scripts ...string) {
	t.Helper()
	body := "#!/bin/sh\nset -eu\nMIGRATIONS=\"\n"
	for i, s := range scripts {
		body += fmt.Sprintf("0.%d.0 %s\n", i+2, s)
	}
	body += "\"\nexit 0\n"
	p := filepath.Join(dir, "migrations", "run.sh")
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}

// TestPayloadManifestsAgree pins tools/payload.sh's manifest to
// cmd/rkit/assemble.go's for every component that carries extras. The gateway
// case is the regression: it is the component whose directory-shaped member the
// shell path silently dropped.
func TestPayloadManifestsAgree(t *testing.T) {
	cases := []struct {
		comp string
		// wantUpdaterInstall is checked against the REAL inner/<comp>/ tree,
		// not a fixture: updater.install.sh comes from this repo's own inner/
		// (like install.sh), not from the srcFixture files below, so both
		// manifest functions resolve it independent of `files`. edge and
		// gateway carry a real, committed inner/<comp>/updater.install.sh
		// (Ruling E); cli, agent and relay do not.
		wantUpdaterInstall bool
		files              []string
	}{
		// migrations/component.conf is NOT scenery: it is a NON-.sh member, and
		// it is the only thing in this table that can tell the two globs
		// apart. tools/payload.sh globs migrations/* while assemble.go globbed
		// migrations/*.sh, and with a fixture made of nothing but scripts the
		// two lists agreed while the shipped sets would not have. The gateway's
		// migrations/ is all scripts TODAY; the first data file added to it is
		// the release where they diverge.
		{"gateway", true, []string{"update.sh", "migrations/run.sh", "migrations/v0_1_to_v0_2.sh", "migrations/component.conf"}},
		// edge and cli take the SHARED ladder: the runner and rungs come from
		// inner/_shared/migrations (both manifests glob the real directory), and
		// component.conf + ledger come from the component source. Both are
		// required — the shared runner has no component defaults — so the fixture
		// carries them.
		{"cli", false, []string{"update.sh", "migrations/component.conf", "migrations/ledger"}},
		{"edge", true, []string{"update.sh", "updater.update.sh", "migrations/component.conf", "migrations/ledger"}},
		// relay is PRIVATE and gated, and was the last component left out of
		// this comparison: tools/release.sh's do_release_relay open-coded
		// `install.sh update.sh updater.update.sh` instead of reading the
		// manifest, because relay takes install.sh from its component source
		// while the public components take theirs from inner/<comp>/. That is a
		// difference in install.sh's PROVENANCE, which is not a manifest member
		// on either side (build.go resolves it and passes it to assemble()
		// separately), so the manifest applies to relay unchanged — and this row
		// is what keeps the two sides of it pinned together.
		//
		// Since the 0.2.2 root-only collapse relay also takes the SHARED
		// ladder, contributing its own component.conf + ledger + the
		// unit-derived adoption rung.
		{"relay", false, []string{"update.sh", "updater.update.sh",
			"migrations/component.conf", "migrations/ledger",
			"migrations/adopt_unit_home_tree.sh"}},
		{"agent", false, nil},
	}
	for _, tc := range cases {
		t.Run(tc.comp, func(t *testing.T) {
			src := srcFixture(t, tc.files...)
			if tc.comp == "gateway" {
				ledgerRunner(t, src, "v0_1_to_v0_2.sh")
			}
			if tc.comp == "edge" || tc.comp == "cli" {
				// The ledger must name a rung the SHARED directory really
				// carries, because both manifests cross-check it.
				if err := os.WriteFile(filepath.Join(src, "migrations", "ledger"),
					[]byte("0.2.0 stale_user_bins.sh\n"), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			if tc.comp == "relay" {
				// relay's real ledger shape: the shared sweep first, then its
				// own adoption rung (which the fixture stages beside it).
				if err := os.WriteFile(filepath.Join(src, "migrations", "ledger"),
					[]byte("0.2.2 stale_user_bins.sh\n0.2.2 adopt_unit_home_tree.sh\n"), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			if tc.comp == "edge" {
				// extraPayload resolves edge covers out of the edge.web tree;
				// point it at a fixture so the names are comparable without
				// depending on a sibling worktree being present.
				t.Setenv("EDGE_WEB_DIR", srcFixture(t, "admin.html", "login.html"))
			}
			shell := shellManifest(t, tc.comp, src)
			goSide := goManifest(t, tc.comp, src)
			if !reflect.DeepEqual(shell, goSide) {
				t.Errorf("assembly paths disagree for %s:\n  tools/payload.sh: %v\n  assemble.go:      %v",
					tc.comp, shell, goSide)
			}
			// Both sides agreeing is not the same as both sides being RIGHT —
			// they could agree by both having silently stopped staging the
			// file. Assert membership directly, against the real inner/
			// tree, so removing inner/edge or inner/gateway's committed
			// updater.install.sh (or wrongly adding one under inner/cli)
			// reddens here by name, not just as a disagreement.
			if got := hasMember(shell, "updater.install.sh"); got != tc.wantUpdaterInstall {
				t.Errorf("%s manifest has updater.install.sh=%v, want %v (real inner/%s/updater.install.sh presence): %v",
					tc.comp, got, tc.wantUpdaterInstall, tc.comp, shell)
			}
		})
	}
}

// hasMember reports whether name is in list.
func hasMember(list []string, name string) bool {
	for _, m := range list {
		if m == name {
			return true
		}
	}
	return false
}

// TestPayloadManifestsAgreeOnANewMigration is the property the file-set
// comparison exists for: a migration added to the gateway repo must appear on
// BOTH sides with no edit to either manifest. A hardcoded list on either side
// passes the fixed case above and fails this one.
func TestPayloadManifestsAgreeOnANewMigration(t *testing.T) {
	src := srcFixture(t, "update.sh",
		"migrations/run.sh", "migrations/v0_1_to_v0_2.sh", "migrations/v2_to_v3.sh")
	ledgerRunner(t, src, "v0_1_to_v0_2.sh", "v2_to_v3.sh")

	shell := shellManifest(t, "gateway", src)
	goSide := goManifest(t, "gateway", src)
	if !reflect.DeepEqual(shell, goSide) {
		t.Fatalf("assembly paths disagree after a migration was added:\n  tools/payload.sh: %v\n  assemble.go:      %v",
			shell, goSide)
	}
	// updater.install.sh rides too: gateway's real, committed
	// inner/gateway/updater.install.sh, resolved independent of this
	// fixture's srcDir — same as install.sh's own provenance.
	want := []string{"migrations/run.sh", "migrations/v0_1_to_v0_2.sh", "migrations/v2_to_v3.sh", "update.sh", "updater.install.sh"}
	if !reflect.DeepEqual(shell, want) {
		t.Errorf("manifest = %v, want %v", shell, want)
	}
}

// TestPayloadManifestsAgreeOnANonScriptMigrationMember is the same property for
// the file that is NOT a script. A ladder directory holds more than rungs — a
// ledger, a component.conf — and each side globbing a different pattern
// produces two zips that differ by exactly those files, with both sides still
// carrying a comment claiming they mirror each other. Stated on its own so the
// reason survives a rewrite of the table above.
func TestPayloadManifestsAgreeOnANonScriptMigrationMember(t *testing.T) {
	src := srcFixture(t, "update.sh",
		"migrations/run.sh", "migrations/v0_1_to_v0_2.sh",
		"migrations/component.conf", "migrations/ledger-notes.txt")
	ledgerRunner(t, src, "v0_1_to_v0_2.sh")

	shell := shellManifest(t, "gateway", src)
	goSide := goManifest(t, "gateway", src)
	if !reflect.DeepEqual(shell, goSide) {
		t.Fatalf("assembly paths disagree on a non-script migrations/ member:\n  tools/payload.sh: %v\n  assemble.go:      %v",
			shell, goSide)
	}
	for _, want := range []string{"migrations/component.conf", "migrations/ledger-notes.txt"} {
		var found bool
		for _, m := range shell {
			if m == want {
				found = true
			}
		}
		if !found {
			t.Errorf("neither manifest ships %s: %v", want, shell)
		}
	}
}

// TestSharedMigrationScriptsExcludeTestSuites states what the shared ladder's
// glob must NOT pick up. adopt_updater_unit_test.sh sat beside its subject and
// was staged, chmod 0755, into every edge, cli and relay zip — 25 KB of test
// harness on every production host. The suite has moved to
// tools/adopt_updater_unit.test.sh; this is the lock that keeps the next one
// out, and tools/payload.test.sh asserts the same thing on the shell side.
func TestSharedMigrationScriptsExcludeTestSuites(t *testing.T) {
	repo := t.TempDir()
	dir := filepath.Join(repo, "inner", "_shared", "migrations")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"run.sh", "lib_paths.sh", "adopt_updater_unit.test.sh", "adopt_updater_unit_test.sh"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	got, err := sharedMigrationScripts(repo)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, p := range got {
		names = append(names, filepath.Base(p))
	}
	sort.Strings(names)
	want := []string{"lib_paths.sh", "run.sh"}
	if !reflect.DeepEqual(names, want) {
		t.Errorf("sharedMigrationScripts staged %v, want %v — a test suite is not payload", names, want)
	}
}

// TestGatewayManifestCarriesTheRunner states the invariant on its own, so the
// reason for all of this survives a refactor of the comparison above: whatever
// else changes, a gateway payload names migrations/run.sh.
func TestGatewayManifestCarriesTheRunner(t *testing.T) {
	src := srcFixture(t, "update.sh", "migrations/run.sh", "migrations/v0_1_to_v0_2.sh")
	ledgerRunner(t, src, "v0_1_to_v0_2.sh")
	for name, manifest := range map[string][]string{
		"tools/payload.sh":     shellManifest(t, "gateway", src),
		"cmd/rkit/assemble.go": goManifest(t, "gateway", src),
	} {
		var found bool
		for _, m := range manifest {
			if m == "migrations/run.sh" {
				found = true
			}
		}
		if !found {
			t.Errorf("%s: gateway manifest %v has no migrations/run.sh", name, manifest)
		}
	}
}
