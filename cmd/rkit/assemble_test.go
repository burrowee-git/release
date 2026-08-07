package main

import (
	"archive/zip"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/burrowee-git/release-kit/build"
	"github.com/burrowee-git/release-kit/pack"
)

// TestAssembleZipContents fabricates built-binary files for two targets plus
// a fake dispatcher and a fake install.sh, calls assemble, and asserts each
// produced zip contains exactly {component bins, burrowee, install.sh} — flat
// (basenames only), nothing else.
func TestAssembleZipContents(t *testing.T) {
	outRoot := t.TempDir()
	stamp := "v0.1.0.2026.07.13.deadbeef"

	writeFile := func(dir, name string) string {
		t.Helper()
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte("fake-"+name), 0o755); err != nil {
			t.Fatal(err)
		}
		return p
	}

	binDir := t.TempDir()
	compArts := []build.Artifact{
		{Bin: "burrowee-cli", OS: "linux", Arch: "amd64",
			Path: writeFile(filepath.Join(binDir, "linux-amd64"), "burrowee-cli")},
		{Bin: "burrowee-cli-updater", OS: "linux", Arch: "amd64",
			Path: writeFile(filepath.Join(binDir, "linux-amd64"), "burrowee-cli-updater")},
		{Bin: "burrowee-cli", OS: "darwin", Arch: "arm64",
			Path: writeFile(filepath.Join(binDir, "darwin-arm64"), "burrowee-cli")},
		{Bin: "burrowee-cli-updater", OS: "darwin", Arch: "arm64",
			Path: writeFile(filepath.Join(binDir, "darwin-arm64"), "burrowee-cli-updater")},
	}
	dispArts := []build.Artifact{
		{Bin: "burrowee", OS: "linux", Arch: "amd64",
			Path: writeFile(filepath.Join(binDir, "disp-linux-amd64"), "burrowee")},
		{Bin: "burrowee", OS: "darwin", Arch: "arm64",
			Path: writeFile(filepath.Join(binDir, "disp-darwin-arm64"), "burrowee")},
	}
	installSh := writeFile(t.TempDir(), "install.sh")

	zips, err := assemble("cli", stamp, outRoot, installSh, nil, compArts, dispArts)
	if err != nil {
		t.Fatal(err)
	}
	if len(zips) != 2 {
		t.Fatalf("got %d zips, want 2: %v", len(zips), zips)
	}

	want := map[string][]string{
		filepath.Join(outRoot, stamp, "burrowee-cli-linux-amd64.zip"):  {"burrowee", "burrowee-cli", "burrowee-cli-updater", "install.sh"},
		filepath.Join(outRoot, stamp, "burrowee-cli-darwin-arm64.zip"): {"burrowee", "burrowee-cli", "burrowee-cli-updater", "install.sh"},
	}

	gotZips := map[string]bool{}
	for _, z := range zips {
		gotZips[z] = true
	}
	for zp, wantEntries := range want {
		if !gotZips[zp] {
			t.Errorf("expected zip %s in result %v", zp, zips)
			continue
		}
		r, err := zip.OpenReader(zp)
		if err != nil {
			t.Fatalf("open %s: %v", zp, err)
		}
		var got []string
		for _, f := range r.File {
			got = append(got, f.Name)
		}
		r.Close()
		sort.Strings(got)
		sortedWant := append([]string(nil), wantEntries...)
		sort.Strings(sortedWant)
		if !reflect.DeepEqual(got, sortedWant) {
			t.Errorf("%s entries = %v, want %v", zp, got, sortedWant)
		}
	}
}

// TestAssembleWithExtras asserts that extras (edge update scripts + nested
// covers/ pages) ride in every produced zip alongside bins + install.sh, with
// their in-archive names preserved (including the covers/ path prefix).
func TestAssembleWithExtras(t *testing.T) {
	outRoot := t.TempDir()
	stamp := "v0.1.0.2026.07.13.deadbeef"
	src := t.TempDir()
	write := func(dir, name string) string {
		t.Helper()
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte("x-"+name), 0o755); err != nil {
			t.Fatal(err)
		}
		return p
	}

	compArts := []build.Artifact{
		{Bin: "burrowee-edge", OS: "linux", Arch: "amd64", Path: write(filepath.Join(src, "b"), "burrowee-edge")},
	}
	dispArts := []build.Artifact{
		{Bin: "burrowee", OS: "linux", Arch: "amd64", Path: write(filepath.Join(src, "d"), "burrowee")},
	}
	installSh := write(t.TempDir(), "install.sh")
	extras := []pack.Content{
		{Src: write(t.TempDir(), "update.sh"), Name: "update.sh"},
		{Src: write(t.TempDir(), "updater.update.sh"), Name: "updater.update.sh"},
		{Src: write(t.TempDir(), "admin.html"), Name: "covers/admin.html"},
		{Src: write(t.TempDir(), "login.html"), Name: "covers/default.html"},
	}

	zips, err := assemble("edge", stamp, outRoot, installSh, extras, compArts, dispArts)
	if err != nil {
		t.Fatal(err)
	}
	if len(zips) != 1 {
		t.Fatalf("got %d zips, want 1: %v", len(zips), zips)
	}
	r, err := zip.OpenReader(zips[0])
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	var got []string
	for _, f := range r.File {
		got = append(got, f.Name)
	}
	sort.Strings(got)
	want := []string{"burrowee", "burrowee-edge", "covers/admin.html", "covers/default.html", "install.sh", "update.sh", "updater.update.sh"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("entries = %v, want %v", got, want)
	}
}

// TestExtraPayloadUpdateScripts asserts each component's scripted payload:
// gateway + cli carry update.sh but no updater.update.sh (their updater
// self-updates by an in-process binary swap), while edge + relay carry both.
// gateway additionally carries its whole migrations/ dir. A missing file is
// fail-loud (returned error) for every scripted component.
func TestExtraPayloadUpdateScripts(t *testing.T) {
	names := func(cs []pack.Content) []string {
		var out []string
		for _, c := range cs {
			out = append(out, c.Name)
		}
		sort.Strings(out)
		return out
	}
	writeSrc := func(t *testing.T, files ...string) string {
		t.Helper()
		dir := t.TempDir()
		for _, f := range files {
			p := filepath.Join(dir, f)
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(p, []byte("x"), 0o755); err != nil {
				t.Fatal(err)
			}
		}
		return dir
	}
	// writeLedger overwrites migrations/run.sh in dir with a runner whose
	// MIGRATIONS= ledger names exactly these scripts. The runner is the source
	// of truth for what will be walked at install time, so a fixture that ships
	// a placeholder run.sh cannot exercise the ledger check at all.
	writeLedger := func(t *testing.T, dir string, scripts ...string) {
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

	// Every script in migrations/ ships, discovered by glob — adding a migration
	// must not require a change here, or the runner's ledger could name a script
	// that is not in the zip.
	t.Run("gateway ships update.sh plus every migration", func(t *testing.T) {
		src := writeSrc(t, "update.sh",
			filepath.Join("migrations", "run.sh"),
			filepath.Join("migrations", "v1_to_v2.sh"),
			filepath.Join("migrations", "v2_to_v3.sh"))
		writeLedger(t, src, "v1_to_v2.sh", "v2_to_v3.sh")
		got, err := extraPayload("gateway", src)
		if err != nil {
			t.Fatal(err)
		}
		want := []string{"migrations/run.sh", "migrations/v1_to_v2.sh", "migrations/v2_to_v3.sh", "update.sh"}
		if !reflect.DeepEqual(names(got), want) {
			t.Errorf("gateway extras = %v, want %v", names(got), want)
		}
	})

	// The zip entry name must be a literal forward-slash path: archive members
	// are always "/"-separated, and a filepath.Join here would silently produce
	// a backslash member the moment this is built anywhere non-unix.
	t.Run("the migration's zip name is slash-separated", func(t *testing.T) {
		src := writeSrc(t, "update.sh", filepath.Join("migrations", "run.sh"), filepath.Join("migrations", "v1_to_v2.sh"))
		writeLedger(t, src, "v1_to_v2.sh")
		got, err := extraPayload("gateway", src)
		if err != nil {
			t.Fatal(err)
		}
		var found bool
		for _, c := range got {
			if c.Name == "migrations/v1_to_v2.sh" {
				found = true
			}
			if strings.Contains(c.Name, `\`) {
				t.Errorf("zip member %q contains a backslash", c.Name)
			}
		}
		if !found {
			t.Errorf("no migrations/v1_to_v2.sh member in %v", names(got))
		}
	})

	// Fail-loud, not best-effort: a gateway zip without the runner turns every
	// upgrade that needs a migration into a daemon that comes back without its
	// state, which is far worse than a build that stops here.
	t.Run("gateway without the runner is a build error", func(t *testing.T) {
		src := writeSrc(t, "update.sh")
		if _, err := extraPayload("gateway", src); err == nil {
			t.Error("missing migrations/run.sh accepted, want a build error")
		}
	})

	// The ledger, not the directory listing, is what the runner walks. A row
	// added to MIGRATIONS= whose script was never committed makes the runner
	// warn and skip — and the caller then records the version, gating that rung
	// off on every host forever. The glob would ship the zip green, so the
	// build is the last place it can be caught.
	t.Run("a ledger row with no script is a build error", func(t *testing.T) {
		src := writeSrc(t, "update.sh",
			filepath.Join("migrations", "run.sh"),
			filepath.Join("migrations", "v1_to_v2.sh"))
		writeLedger(t, src, "v1_to_v2.sh", "v2_to_v3.sh") // v2_to_v3.sh not committed
		_, err := extraPayload("gateway", src)
		if err == nil {
			t.Fatal("a ledger row naming a missing script was accepted, want a build error")
		}
		if !strings.Contains(err.Error(), "v2_to_v3.sh") {
			t.Errorf("error does not name the missing migration: %v", err)
		}
	})

	// A run.sh with no ledger at all is not the runner. Accepting it would mean
	// the check silently passes on every future build.
	t.Run("a runner with no ledger is a build error", func(t *testing.T) {
		src := writeSrc(t, "update.sh",
			filepath.Join("migrations", "run.sh"),
			filepath.Join("migrations", "v1_to_v2.sh"))
		if _, err := extraPayload("gateway", src); err == nil {
			t.Error("a run.sh with no MIGRATIONS= ledger was accepted, want a build error")
		}
	})

	// An empty ledger is legitimate: a release before the first migration was
	// written ships a runner with nothing to walk.
	t.Run("an empty ledger is fine", func(t *testing.T) {
		src := writeSrc(t, "update.sh", filepath.Join("migrations", "run.sh"))
		writeLedger(t, src)
		got, err := extraPayload("gateway", src)
		if err != nil {
			t.Fatalf("empty ledger rejected: %v", err)
		}
		if want := []string{"migrations/run.sh", "update.sh"}; !reflect.DeepEqual(names(got), want) {
			t.Errorf("gateway extras = %v, want %v", names(got), want)
		}
	})

	// A migrations/ dir holding scripts but no runner is the subtler mistake:
	// nothing invokes them, so the zip looks complete and migrates nothing.
	t.Run("migrations without the runner is a build error", func(t *testing.T) {
		src := writeSrc(t, "update.sh", filepath.Join("migrations", "v1_to_v2.sh"))
		if _, err := extraPayload("gateway", src); err == nil {
			t.Error("migrations/ without run.sh accepted, want a build error")
		}
	})

	// Only gateway needs it — cli shares the update.sh arm but has no such
	// config move, so requiring the file there would break its builds.
	t.Run("cli does not require the migration", func(t *testing.T) {
		src := writeSrc(t, "update.sh")
		got, err := extraPayload("cli", src)
		if err != nil {
			t.Fatalf("cli should not require the gateway migration: %v", err)
		}
		for _, c := range got {
			if strings.Contains(c.Name, "migrations/") {
				t.Errorf("cli extras include %q", c.Name)
			}
		}
	})

	t.Run("cli ships update.sh only", func(t *testing.T) {
		src := writeSrc(t, "update.sh")
		got, err := extraPayload("cli", src)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{"update.sh"}; !reflect.DeepEqual(names(got), want) {
			t.Errorf("cli extras = %v, want %v", names(got), want)
		}
	})

	t.Run("edge ships both update scripts", func(t *testing.T) {
		src := writeSrc(t, "update.sh", "updater.update.sh")
		got, err := extraPayload("edge", src)
		if err != nil {
			t.Fatal(err)
		}
		// edge also appends covers/*, resolved from a non-existent EDGE_WEB_DIR
		// here; assert only that both update scripts are present.
		set := map[string]bool{}
		for _, n := range names(got) {
			set[n] = true
		}
		if !set["update.sh"] || !set["updater.update.sh"] {
			t.Errorf("edge extras = %v, want both update scripts", names(got))
		}
	})

	for _, comp := range []string{"gateway", "cli", "relay"} {
		t.Run("missing update.sh is fail-loud: "+comp, func(t *testing.T) {
			if _, err := extraPayload(comp, t.TempDir()); err == nil {
				t.Errorf("%s: expected error for missing update.sh, got nil", comp)
			}
		})
	}
}

// TestLedgerMigrations pins the parse against the shape migrations/run.sh
// actually writes, and against the mangled runners a refactor there could
// produce. It reads the ledger the same way the runner does — word-split into
// (version, script) pairs — so the two cannot disagree about what it says.
func TestLedgerMigrations(t *testing.T) {
	const header = "#!/bin/sh\n" +
		"# THE LEDGER — \"<version-this-upgrades-to> <script>\", oldest first.\n" +
		"# Adding a migration means adding ONE row to the ledger below.\n"

	t.Run("the canonical multi-row ledger", func(t *testing.T) {
		got, err := ledgerMigrations(header + "MIGRATIONS=\"\n0.2.0 v1_to_v2.sh\n0.2.5 v2_to_v3.sh\n\"\n\nGW_HOME=x\n")
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{"v1_to_v2.sh", "v2_to_v3.sh"}; !reflect.DeepEqual(got, want) {
			t.Errorf("scripts = %v, want %v", got, want)
		}
	})

	t.Run("a single-line ledger", func(t *testing.T) {
		got, err := ledgerMigrations("MIGRATIONS=\"0.2.0 v1_to_v2.sh\"\n")
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{"v1_to_v2.sh"}; !reflect.DeepEqual(got, want) {
			t.Errorf("scripts = %v, want %v", got, want)
		}
	})

	t.Run("an empty ledger names nothing", func(t *testing.T) {
		got, err := ledgerMigrations("MIGRATIONS=\"\n\"\n")
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 0 {
			t.Errorf("scripts = %v, want none", got)
		}
	})

	// The header quotes the assignment inside a comment. Matching that would
	// read a documentation example as the ledger.
	t.Run("a commented or indented assignment is not the ledger", func(t *testing.T) {
		src := "# MIGRATIONS=\"0.9.9 not_real.sh\"\n" +
			"    MIGRATIONS=\"0.9.8 also_not_real.sh\"\n" +
			"MIGRATIONS=\"\n0.2.0 v1_to_v2.sh\n\"\n"
		got, err := ledgerMigrations(src)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{"v1_to_v2.sh"}; !reflect.DeepEqual(got, want) {
			t.Errorf("scripts = %v, want %v", got, want)
		}
	})

	for name, src := range map[string]string{
		"no ledger at all":       "#!/bin/sh\nGW_HOME=x\n",
		"unterminated":           "MIGRATIONS=\"\n0.2.0 v1_to_v2.sh\n",
		"a row missing a script": "MIGRATIONS=\"\n0.2.0 v1_to_v2.sh\n0.2.5\n\"\n",
		"two assignments":        "MIGRATIONS=\"\n0.2.0 a.sh\n\"\nMIGRATIONS=\"\n0.3.0 b.sh\n\"\n",
	} {
		t.Run("refused: "+name, func(t *testing.T) {
			if got, err := ledgerMigrations(src); err == nil {
				t.Errorf("accepted a broken ledger, got %v", got)
			}
		})
	}
}
