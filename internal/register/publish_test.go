package register

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func sha256Hex(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

type fakeGetter struct{ resp map[string]string }

func (f *fakeGetter) Get(url string) (*http.Response, error) {
	body, ok := f.resp[url]
	st := 200
	if !ok {
		st, body = 404, "not found"
	}
	return &http.Response{StatusCode: st, Body: io.NopCloser(strings.NewReader(body))}, nil
}

type fakePutter struct{ puts map[string]string }

func (f *fakePutter) Put(_ context.Context, key string, body []byte, _ string) error {
	if f.puts == nil {
		f.puts = map[string]string{}
	}
	f.puts[key] = string(body)
	return nil
}

const ghBase = "https://github.com/burrowee-git/release/releases/download/cli/v1"

func cliCatalog(zipSha string) string {
	return `{"version":"v1","semver":"0.0.0","artifacts":{"darwin-arm64":{"url_or_key":"` +
		ghBase + `/burrowee-cli-darwin-arm64.zip","sha256":"` + zipSha + `","size":3}},` +
		`"sums_ref":"` + ghBase + `/SHA256SUMS.txt","minisig_ref":"` + ghBase + `/SHA256SUMS.txt.minisig"}`
}

func TestPublishHappyPath(t *testing.T) {
	g := &fakeGetter{resp: map[string]string{
		"https://c.example/api/v1/releases/cli/current": cliCatalog(sha256Hex("ZIP")),
		ghBase + "/burrowee-cli-darwin-arm64.zip":       "ZIP",
		ghBase + "/SHA256SUMS.txt":                      "SUMS",
		ghBase + "/SHA256SUMS.txt.minisig":              "SIG",
	}}
	p := &fakePutter{}
	err := Publish(context.Background(), PublishDeps{ConsoleURL: "https://c.example", HTTP: g, R2: p, Out: io.Discard}, "cli", "")
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if p.puts["cli/v1/burrowee-cli-darwin-arm64.zip"] != "ZIP" {
		t.Errorf("zip not put: %v", p.puts)
	}
	if p.puts["cli/v1/SHA256SUMS.txt"] != "SUMS" || p.puts["cli/v1/SHA256SUMS.txt.minisig"] != "SIG" {
		t.Errorf("sums/minisig not put: %v", p.puts)
	}
}

func TestPublishSha256MismatchAborts(t *testing.T) {
	g := &fakeGetter{resp: map[string]string{
		"https://c.example/api/v1/releases/cli/current": cliCatalog("deadbeef"), // wrong hash
		ghBase + "/burrowee-cli-darwin-arm64.zip":       "ZIP",
	}}
	p := &fakePutter{}
	err := Publish(context.Background(), PublishDeps{ConsoleURL: "https://c.example", HTTP: g, R2: p, Out: io.Discard}, "cli", "")
	if err == nil || !strings.Contains(err.Error(), "sha256") {
		t.Fatalf("want sha256 error, got %v", err)
	}
	if len(p.puts) != 0 {
		t.Errorf("must not PUT on mismatch: %v", p.puts)
	}
}

// TestPublishRelayAllowed verifies that relay is no longer refused by Publish()
// and proceeds to the catalog-fetch path (returning a catalog error if no row).
func TestPublishRelayAllowed(t *testing.T) {
	// fakeGetter returns 404 for the relay catalog; Publish should get a catalog
	// error (not a relay-refused error).
	g := &fakeGetter{resp: map[string]string{}} // all 404s
	err := Publish(context.Background(), PublishDeps{ConsoleURL: "https://c.example", HTTP: g, R2: &fakePutter{}, Out: io.Discard}, "relay", "")
	if err == nil {
		t.Fatal("want error from catalog fetch, got nil")
	}
	if strings.Contains(err.Error(), "relay is private") {
		t.Fatalf("relay must no longer be refused at the top of Publish(); got: %v", err)
	}
}

// TestPublishFromDirHappyPath verifies that PublishFromDir uploads six files to
// R2 under relay/<stamp>/ and verifies sha256 before uploading.
func TestPublishFromDirHappyPath(t *testing.T) {
	dir := t.TempDir()
	stamp := "v0.1.3.2026.06.21.abc12345"

	platforms := []string{"darwin-arm64", "darwin-amd64", "linux-arm64", "linux-amd64"}
	bodies := map[string]string{}
	for _, plat := range platforms {
		bodies["latest."+plat+".zip"] = "ZIP-" + plat
	}

	// Write zip files.
	for name, body := range bodies {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	// Build SHA256SUMS.txt.
	var sums strings.Builder
	for _, plat := range platforms {
		name := "latest." + plat + ".zip"
		h := sha256.Sum256([]byte(bodies[name]))
		fmt.Fprintf(&sums, "%s  %s\n", hex.EncodeToString(h[:]), name)
	}
	sumsContent := sums.String()
	if err := os.WriteFile(filepath.Join(dir, "SHA256SUMS.txt"), []byte(sumsContent), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "SHA256SUMS.txt.minisig"), []byte("SIG"), 0o644); err != nil {
		t.Fatal(err)
	}

	p := &fakePutter{}
	if err := PublishFromDir(context.Background(), p, dir, stamp, io.Discard); err != nil {
		t.Fatalf("PublishFromDir: %v", err)
	}

	// Expect 4 zips + SHA256SUMS.txt + SHA256SUMS.txt.minisig = 6 keys.
	if len(p.puts) != 6 {
		t.Fatalf("want 6 R2 puts, got %d: %v", len(p.puts), p.puts)
	}
	for _, plat := range platforms {
		key := "relay/" + stamp + "/latest." + plat + ".zip"
		if _, ok := p.puts[key]; !ok {
			t.Errorf("missing R2 key %s; got %v", key, p.puts)
		}
	}
	if _, ok := p.puts["relay/"+stamp+"/SHA256SUMS.txt"]; !ok {
		t.Errorf("missing R2 key relay/%s/SHA256SUMS.txt", stamp)
	}
	if _, ok := p.puts["relay/"+stamp+"/SHA256SUMS.txt.minisig"]; !ok {
		t.Errorf("missing R2 key relay/%s/SHA256SUMS.txt.minisig", stamp)
	}
}

// TestPublishFromDirSha256Mismatch verifies that PublishFromDir aborts on a
// sha256 mismatch and does not upload the bad file.
func TestPublishFromDirSha256Mismatch(t *testing.T) {
	dir := t.TempDir()
	stamp := "v0.1.0.test"

	platforms := []string{"darwin-arm64", "darwin-amd64", "linux-arm64", "linux-amd64"}
	for _, plat := range platforms {
		if err := os.WriteFile(filepath.Join(dir, "latest."+plat+".zip"), []byte("ZIP-"+plat), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	// SHA256SUMS.txt with a wrong hash for darwin-arm64.
	var sums strings.Builder
	for _, plat := range platforms {
		name := "latest." + plat + ".zip"
		var h [32]byte
		if plat == "darwin-arm64" {
			h = sha256.Sum256([]byte("WRONG"))
		} else {
			h = sha256.Sum256([]byte("ZIP-" + plat))
		}
		fmt.Fprintf(&sums, "%s  %s\n", hex.EncodeToString(h[:]), name)
	}
	if err := os.WriteFile(filepath.Join(dir, "SHA256SUMS.txt"), []byte(sums.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	p := &fakePutter{}
	err := PublishFromDir(context.Background(), p, dir, stamp, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "sha256 mismatch") {
		t.Fatalf("want sha256 mismatch error, got %v", err)
	}
	if len(p.puts) != 0 {
		t.Errorf("must not PUT on sha256 mismatch: %v", p.puts)
	}
}

// cliCatalogSize returns a catalog JSON with a specific size value for the artifact.
// The sha256 still matches "ZIP" so only the size is wrong.
func cliCatalogSize(size int64) string {
	return `{"version":"v1","semver":"0.0.0","artifacts":{"darwin-arm64":{"url_or_key":"` +
		ghBase + `/burrowee-cli-darwin-arm64.zip","sha256":"` + sha256Hex("ZIP") + `","size":` +
		fmt.Sprint(size) + `}},` +
		`"sums_ref":"` + ghBase + `/SHA256SUMS.txt","minisig_ref":"` + ghBase + `/SHA256SUMS.txt.minisig"}`
}

func TestPublishSizeMismatchAborts(t *testing.T) {
	// Catalog says size=99 but body is "ZIP" (3 bytes) — size check fires before sha256.
	g := &fakeGetter{resp: map[string]string{
		"https://c.example/api/v1/releases/cli/current": cliCatalogSize(99),
		ghBase + "/burrowee-cli-darwin-arm64.zip":       "ZIP",
	}}
	p := &fakePutter{}
	err := Publish(context.Background(), PublishDeps{ConsoleURL: "https://c.example", HTTP: g, R2: p, Out: io.Discard}, "cli", "")
	if err == nil || !strings.Contains(err.Error(), "size mismatch") {
		t.Fatalf("want size mismatch error, got %v", err)
	}
	if len(p.puts) != 0 {
		t.Errorf("must not PUT on size mismatch: %v", p.puts)
	}
}
