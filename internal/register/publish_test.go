package register

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
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
		ghBase + "/burrowee-cli-darwin-arm64.zip":        "ZIP",
		ghBase + "/SHA256SUMS.txt":                       "SUMS",
		ghBase + "/SHA256SUMS.txt.minisig":               "SIG",
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
		ghBase + "/burrowee-cli-darwin-arm64.zip":        "ZIP",
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

func TestPublishRelayRefused(t *testing.T) {
	err := Publish(context.Background(), PublishDeps{ConsoleURL: "https://c.example", HTTP: &fakeGetter{}, R2: &fakePutter{}, Out: io.Discard}, "relay", "")
	if err == nil || !strings.Contains(err.Error(), "relay") {
		t.Fatalf("want relay-refused error, got %v", err)
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
		ghBase + "/burrowee-cli-darwin-arm64.zip":        "ZIP",
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
