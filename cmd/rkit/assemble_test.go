package main

import (
	"archive/zip"
	"os"
	"path/filepath"
	"reflect"
	"sort"
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

// TestExtraPayloadUpdateScripts asserts each component's update-script payload:
// gateway + cli ship update.sh ONLY (in-process updater self-update — no
// updater.update.sh), while edge + relay ship both. A missing update.sh is
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
			if err := os.WriteFile(filepath.Join(dir, f), []byte("x"), 0o755); err != nil {
				t.Fatal(err)
			}
		}
		return dir
	}

	t.Run("gateway ships update.sh only", func(t *testing.T) {
		src := writeSrc(t, "update.sh")
		got, err := extraPayload("gateway", src)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{"update.sh"}; !reflect.DeepEqual(names(got), want) {
			t.Errorf("gateway extras = %v, want %v", names(got), want)
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
