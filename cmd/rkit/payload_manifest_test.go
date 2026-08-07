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

// goManifest returns extraPayload's member names for a component.
func goManifest(t *testing.T, comp, srcDir string) []string {
	t.Helper()
	extras, err := extraPayload(comp, srcDir)
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
		comp  string
		files []string
	}{
		{"gateway", []string{"update.sh", "migrations/run.sh", "migrations/v1_to_v2.sh"}},
		{"cli", []string{"update.sh"}},
		{"edge", []string{"update.sh", "updater.update.sh"}},
		// relay is PRIVATE and gated, and was the last component left out of
		// this comparison: tools/release.sh's do_release_relay open-coded
		// `install.sh update.sh updater.update.sh` instead of reading the
		// manifest, because relay takes install.sh from its component source
		// while the public components take theirs from inner/<comp>/. That is a
		// difference in install.sh's PROVENANCE, which is not a manifest member
		// on either side (build.go resolves it and passes it to assemble()
		// separately), so the manifest applies to relay unchanged — and this row
		// is what keeps the two sides of it pinned together.
		{"relay", []string{"update.sh", "updater.update.sh"}},
		{"agent", nil},
	}
	for _, tc := range cases {
		t.Run(tc.comp, func(t *testing.T) {
			src := srcFixture(t, tc.files...)
			if tc.comp == "gateway" {
				ledgerRunner(t, src, "v1_to_v2.sh")
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
		})
	}
}

// TestPayloadManifestsAgreeOnANewMigration is the property the file-set
// comparison exists for: a migration added to the gateway repo must appear on
// BOTH sides with no edit to either manifest. A hardcoded list on either side
// passes the fixed case above and fails this one.
func TestPayloadManifestsAgreeOnANewMigration(t *testing.T) {
	src := srcFixture(t, "update.sh",
		"migrations/run.sh", "migrations/v1_to_v2.sh", "migrations/v2_to_v3.sh")
	ledgerRunner(t, src, "v1_to_v2.sh", "v2_to_v3.sh")

	shell := shellManifest(t, "gateway", src)
	goSide := goManifest(t, "gateway", src)
	if !reflect.DeepEqual(shell, goSide) {
		t.Fatalf("assembly paths disagree after a migration was added:\n  tools/payload.sh: %v\n  assemble.go:      %v",
			shell, goSide)
	}
	want := []string{"migrations/run.sh", "migrations/v1_to_v2.sh", "migrations/v2_to_v3.sh", "update.sh"}
	if !reflect.DeepEqual(shell, want) {
		t.Errorf("manifest = %v, want %v", shell, want)
	}
}

// TestGatewayManifestCarriesTheRunner states the invariant on its own, so the
// reason for all of this survives a refactor of the comparison above: whatever
// else changes, a gateway payload names migrations/run.sh.
func TestGatewayManifestCarriesTheRunner(t *testing.T) {
	src := srcFixture(t, "update.sh", "migrations/run.sh", "migrations/v1_to_v2.sh")
	ledgerRunner(t, src, "v1_to_v2.sh")
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
