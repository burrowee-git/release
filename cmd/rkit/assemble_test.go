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

	// sharedRepo is a fixture RELEASE repo carrying inner/_shared/migrations.
	// The gateway and relay cases never read it — they do not take the shared
	// ladder — but extraPayload takes it as a parameter, and handing those cases
	// a directory that exists keeps a failure there from being mistaken for the
	// missing-shared-ladder error the shared cases assert on.
	sharedRepo := func(t *testing.T, files ...string) string {
		t.Helper()
		dir := t.TempDir()
		for _, f := range files {
			p := filepath.Join(dir, "inner", "_shared", "migrations", f)
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(p, []byte("x"), 0o755); err != nil {
				t.Fatal(err)
			}
		}
		return dir
	}
	sharedOK := sharedRepo(t, "run.sh", "upgrade.sh", "lib_paths.sh", "lib_stale_user_bins.sh", "stale_user_bins.sh")

	// writeSharedLedger writes migrations/ledger — the DATA-file ledger the
	// shared runner reads, as opposed to the gateway runner's here-string.
	writeSharedLedger := func(t *testing.T, dir string, scripts ...string) {
		t.Helper()
		body := "# ledger\n"
		for i, s := range scripts {
			body += fmt.Sprintf("0.%d.0 %s\n", i+2, s)
		}
		p := filepath.Join(dir, "migrations", "ledger")
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
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
		got, err := extraPayload("gateway", src, sharedOK)
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
		got, err := extraPayload("gateway", src, sharedOK)
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
		if _, err := extraPayload("gateway", src, sharedOK); err == nil {
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
		_, err := extraPayload("gateway", src, sharedOK)
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
		if _, err := extraPayload("gateway", src, sharedOK); err == nil {
			t.Error("a run.sh with no MIGRATIONS= ledger was accepted, want a build error")
		}
	})

	// An empty ledger is legitimate: a release before the first migration was
	// written ships a runner with nothing to walk.
	t.Run("an empty ledger is fine", func(t *testing.T) {
		src := writeSrc(t, "update.sh", filepath.Join("migrations", "run.sh"))
		writeLedger(t, src)
		got, err := extraPayload("gateway", src, sharedOK)
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
		if _, err := extraPayload("gateway", src, sharedOK); err == nil {
			t.Error("migrations/ without run.sh accepted, want a build error")
		}
	})

	// The cli does NOT carry the gateway's migrations — it has its own ladder,
	// and none of the gateway's rungs are on it. It carries the SHARED runner
	// plus its own two files, and nothing named vN_to_vM.
	t.Run("cli carries the shared ladder, not the gateway's", func(t *testing.T) {
		src := writeSrc(t, "update.sh",
			"migrations/component.conf", "migrations/ledger")
		writeSharedLedger(t, src, "stale_user_bins.sh")
		got, err := extraPayload("cli", src, sharedOK)
		if err != nil {
			t.Fatalf("cli should build with the shared ladder: %v", err)
		}
		want := []string{
			"migrations/component.conf", "migrations/ledger",
			"migrations/lib_paths.sh", "migrations/lib_stale_user_bins.sh",
			"migrations/run.sh", "migrations/stale_user_bins.sh", "migrations/upgrade.sh",
			"update.sh",
		}
		if !reflect.DeepEqual(names(got), want) {
			t.Errorf("cli extras = %v, want %v", names(got), want)
		}
	})

	// component.conf and ledger are REQUIRED: the shared runner has no component
	// defaults and refuses without them, so a kit missing either is a component
	// whose every install ends in a refusal.
	for _, missing := range []string{"component.conf", "ledger"} {
		t.Run("shared ladder requires "+missing, func(t *testing.T) {
			files := []string{"update.sh", "migrations/component.conf", "migrations/ledger"}
			src := writeSrc(t, files...)
			writeSharedLedger(t, src, "stale_user_bins.sh")
			if err := os.Remove(filepath.Join(src, "migrations", missing)); err != nil {
				t.Fatal(err)
			}
			if _, err := extraPayload("cli", src, sharedOK); err == nil {
				t.Errorf("a cli source with no migrations/%s was accepted", missing)
			}
		})
	}

	// A ledger row naming a rung that is not staged is the row the runner
	// refuses on — on every host, after the cut.
	t.Run("shared ladger rejects a ledger row with no script", func(t *testing.T) {
		src := writeSrc(t, "update.sh", "migrations/component.conf", "migrations/ledger")
		writeSharedLedger(t, src, "rekey_console.sh")
		if _, err := extraPayload("cli", src, sharedOK); err == nil {
			t.Error("a ledger naming an unstaged rung was accepted")
		}
	})

	// And a shared directory that lost the runner (or the library install.sh
	// sources) is a mis-assembled release, not a component problem.
	for _, missing := range []string{"run.sh", "upgrade.sh", "lib_paths.sh", "lib_stale_user_bins.sh"} {
		t.Run("shared ladder requires shared "+missing, func(t *testing.T) {
			var kept []string
			for _, f := range []string{"run.sh", "upgrade.sh", "lib_paths.sh", "lib_stale_user_bins.sh", "stale_user_bins.sh"} {
				if f != missing {
					kept = append(kept, f)
				}
			}
			src := writeSrc(t, "update.sh", "migrations/component.conf", "migrations/ledger")
			writeSharedLedger(t, src, "stale_user_bins.sh")
			if _, err := extraPayload("cli", src, sharedRepo(t, kept...)); err == nil {
				t.Errorf("a shared ladder with no %s was accepted", missing)
			}
		})
	}

	t.Run("edge ships both update scripts", func(t *testing.T) {
		src := writeSrc(t, "update.sh", "updater.update.sh",
			"migrations/component.conf", "migrations/ledger")
		writeSharedLedger(t, src, "stale_user_bins.sh")
		got, err := extraPayload("edge", src, sharedOK)
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
			if _, err := extraPayload(comp, t.TempDir(), sharedOK); err == nil {
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
