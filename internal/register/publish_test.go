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

type fakeStringPutter struct{ puts map[string]string }

func (f *fakeStringPutter) Put(_ context.Context, key string, body []byte, _ string) error {
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
	p := &fakeStringPutter{}
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
	p := &fakeStringPutter{}
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
	err := Publish(context.Background(), PublishDeps{ConsoleURL: "https://c.example", HTTP: g, R2: &fakeStringPutter{}, Out: io.Discard}, "relay", "")
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

	p := &fakeStringPutter{}
	if err := PublishFromDir(context.Background(), p, "relay", "stable", dir, stamp, io.Discard); err != nil {
		t.Fatalf("PublishFromDir: %v", err)
	}

	// Expect 4 zips + SHA256SUMS.txt + SHA256SUMS.txt.minisig + latest.json = 7 keys.
	if len(p.puts) != 7 {
		t.Fatalf("want 7 R2 puts, got %d: %v", len(p.puts), p.puts)
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

	p := &fakeStringPutter{}
	err := PublishFromDir(context.Background(), p, "relay", "stable", dir, stamp, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "sha256 mismatch") {
		t.Fatalf("want sha256 mismatch error, got %v", err)
	}
	if len(p.puts) != 0 {
		t.Errorf("must not PUT on sha256 mismatch: %v", p.puts)
	}
}

// TestPublishFromDirCLI verifies that PublishFromDir generalises beyond relay:
// for comp="cli" it uploads burrowee-cli-<plat>.zip (not latest.<plat>.zip)
// under cli/<stamp>/ — the key layout the console's presigner and register
// endpoint already expect for a beta cut of any component (spec §4.1/§5.3).
func TestPublishFromDirCLI(t *testing.T) {
	dir := t.TempDir()
	stamp := "v0.1.3.beta.2026.06.21.abc12345"

	platforms := []string{"darwin-arm64", "darwin-amd64", "linux-arm64", "linux-amd64"}
	bodies := map[string]string{}
	for _, plat := range platforms {
		bodies["burrowee-cli-"+plat+".zip"] = "ZIP-" + plat
	}

	for name, body := range bodies {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	var sums strings.Builder
	for _, plat := range platforms {
		name := "burrowee-cli-" + plat + ".zip"
		h := sha256.Sum256([]byte(bodies[name]))
		fmt.Fprintf(&sums, "%s  %s\n", hex.EncodeToString(h[:]), name)
	}
	if err := os.WriteFile(filepath.Join(dir, "SHA256SUMS.txt"), []byte(sums.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "SHA256SUMS.txt.minisig"), []byte("SIG"), 0o644); err != nil {
		t.Fatal(err)
	}

	p := &fakeStringPutter{}
	if err := PublishFromDir(context.Background(), p, "cli", "stable", dir, stamp, io.Discard); err != nil {
		t.Fatalf("PublishFromDir: %v", err)
	}

	if len(p.puts) != 7 {
		t.Fatalf("want 7 R2 puts, got %d: %v", len(p.puts), p.puts)
	}
	for _, plat := range platforms {
		key := "cli/" + stamp + "/burrowee-cli-" + plat + ".zip"
		if _, ok := p.puts[key]; !ok {
			t.Errorf("missing R2 key %s; got %v", key, p.puts)
		}
	}
	if _, ok := p.puts["cli/"+stamp+"/SHA256SUMS.txt"]; !ok {
		t.Errorf("missing R2 key cli/%s/SHA256SUMS.txt", stamp)
	}
	if _, ok := p.puts["cli/"+stamp+"/SHA256SUMS.txt.minisig"]; !ok {
		t.Errorf("missing R2 key cli/%s/SHA256SUMS.txt.minisig", stamp)
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
	p := &fakeStringPutter{}
	err := Publish(context.Background(), PublishDeps{ConsoleURL: "https://c.example", HTTP: g, R2: p, Out: io.Discard}, "cli", "")
	if err == nil || !strings.Contains(err.Error(), "size mismatch") {
		t.Fatalf("want size mismatch error, got %v", err)
	}
	if len(p.puts) != 0 {
		t.Errorf("must not PUT on size mismatch: %v", p.puts)
	}
}

// TestPublishFromDirUploadsTheFifthPlatform is the regression test for the
// first beta cut's broken install: the upload list was a literal four-entry
// platform slice, so when tools/release.sh's TARGETS grew darwin-amd64-legacy
// the R2 push silently published four zips out of five. The register payload
// was built from the real dist contents and advertised all five, so the console
// minted a presigned URL for an object that had never been uploaded and every
// macOS-below-12 host got a 404 from a cut that reported success.
//
// A gateway stage carrying five platforms must upload five zips. Pinning the
// count as well as the key means dropping the fifth arm again fails here rather
// than in production.
func TestPublishFromDirUploadsTheFifthPlatform(t *testing.T) {
	dir := t.TempDir()
	stamp := "v0.2.17.beta.2026.08.28.acd89694"

	platforms := []string{"darwin-arm64", "darwin-amd64", "darwin-amd64-legacy", "linux-arm64", "linux-amd64"}
	bodies := map[string]string{}
	var sums strings.Builder
	for _, plat := range platforms {
		name := "burrowee-gateway-" + plat + ".zip"
		bodies[name] = "ZIP-" + plat
		if err := os.WriteFile(filepath.Join(dir, name), []byte(bodies[name]), 0o644); err != nil {
			t.Fatal(err)
		}
		h := sha256.Sum256([]byte(bodies[name]))
		fmt.Fprintf(&sums, "%s  %s\n", hex.EncodeToString(h[:]), name)
	}
	if err := os.WriteFile(filepath.Join(dir, "SHA256SUMS.txt"), []byte(sums.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "SHA256SUMS.txt.minisig"), []byte("SIG"), 0o644); err != nil {
		t.Fatal(err)
	}

	p := &fakeStringPutter{}
	if err := PublishFromDir(context.Background(), p, "gateway", "stable", dir, stamp, io.Discard); err != nil {
		t.Fatalf("PublishFromDir: %v", err)
	}

	// 5 zips + SHA256SUMS.txt + .minisig + latest.json = 8.
	if len(p.puts) != 8 {
		t.Fatalf("want 8 R2 puts, got %d: %v", len(p.puts), p.puts)
	}
	legacy := "gateway/" + stamp + "/burrowee-gateway-darwin-amd64-legacy.zip"
	if _, ok := p.puts[legacy]; !ok {
		t.Errorf("the legacy zip was never uploaded: missing R2 key %s; got %v", legacy, p.puts)
	}
}

// TestPublishFromDirRelayNeedsNoLegacy pins the other half of the contract:
// the upload set follows SHA256SUMS.txt, so a component that deliberately
// ships no legacy build is not forced to have one. relay is that component —
// it is gated, never installed on a legacy Mac, and does not build the fifth
// platform. A four-platform relay stage must publish cleanly.
func TestPublishFromDirRelayNeedsNoLegacy(t *testing.T) {
	dir := t.TempDir()
	stamp := "v0.2.20.beta.2026.08.28.5c285586"

	platforms := []string{"darwin-arm64", "darwin-amd64", "linux-arm64", "linux-amd64"}
	var sums strings.Builder
	for _, plat := range platforms {
		name := "latest." + plat + ".zip"
		body := "ZIP-" + plat
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		h := sha256.Sum256([]byte(body))
		fmt.Fprintf(&sums, "%s  %s\n", hex.EncodeToString(h[:]), name)
	}
	if err := os.WriteFile(filepath.Join(dir, "SHA256SUMS.txt"), []byte(sums.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "SHA256SUMS.txt.minisig"), []byte("SIG"), 0o644); err != nil {
		t.Fatal(err)
	}

	p := &fakeStringPutter{}
	if err := PublishFromDir(context.Background(), p, "relay", "stable", dir, stamp, io.Discard); err != nil {
		t.Fatalf("PublishFromDir: %v", err)
	}
	if len(p.puts) != 7 {
		t.Fatalf("want 7 R2 puts for a legacy-free relay, got %d: %v", len(p.puts), p.puts)
	}
}

// TestPublishFromDirRefusesAShortBuild pins the floor. Deriving the list from
// SHA256SUMS.txt means an under-built stage would otherwise publish whatever it
// happened to contain and report success — the same silent-shortfall shape as
// the bug above, one level down. A stage missing a base platform is refused by
// name.
func TestPublishFromDirRefusesAShortBuild(t *testing.T) {
	dir := t.TempDir()
	stamp := "v0.2.17.beta.2026.08.28.acd89694"

	// linux-arm64 absent.
	var sums strings.Builder
	for _, plat := range []string{"darwin-arm64", "darwin-amd64", "linux-amd64"} {
		name := "burrowee-gateway-" + plat + ".zip"
		body := "ZIP-" + plat
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		h := sha256.Sum256([]byte(body))
		fmt.Fprintf(&sums, "%s  %s\n", hex.EncodeToString(h[:]), name)
	}
	if err := os.WriteFile(filepath.Join(dir, "SHA256SUMS.txt"), []byte(sums.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	p := &fakeStringPutter{}
	err := PublishFromDir(context.Background(), p, "gateway", "stable", dir, stamp, io.Discard)
	if err == nil {
		t.Fatal("want a refusal for a stage missing linux-arm64, got nil")
	}
	if !strings.Contains(err.Error(), "linux-arm64") {
		t.Errorf("the refusal must name the missing platform, got: %v", err)
	}
	if len(p.puts) != 0 {
		t.Errorf("a refused short build must upload nothing, got %v", p.puts)
	}
}

// TestZipsFromSumsRefusesANonBasename pins the trust boundary on SHA256SUMS.txt.
// zipsFromSums derives filenames from that file's content and they become both
// an os.ReadFile path and an R2 object key, so a crafted line would otherwise
// choose where publish-dir reads and what it writes. Anchoring the prefix and
// suffix does not cover it on its own: every input below satisfies both.
func TestZipsFromSumsRefusesANonBasename(t *testing.T) {
	for _, plat := range []string{
		"../../etc/passwd",
		"/../../etc/passwd",
		"darwin-amd64/../../x",
		"darwin_amd64",
		"Darwin-amd64",
		"",
	} {
		hashByFile := map[string]string{}
		for _, base := range basePlatforms {
			hashByFile["burrowee-gateway-"+base+".zip"] = "hash"
		}
		hashByFile["burrowee-gateway-"+plat+".zip"] = "hash"

		if _, err := zipsFromSums("gateway", hashByFile); err == nil {
			t.Errorf("platform segment %q: want a refusal, got nil", plat)
		}
	}
}

// TestZipsFromSumsAcceptsRealPlatforms is the other half: the check must not
// reject the platforms actually shipped, legacy's two hyphens included.
func TestZipsFromSumsAcceptsRealPlatforms(t *testing.T) {
	hashByFile := map[string]string{}
	want := append([]string{"darwin-amd64-legacy"}, basePlatforms...)
	for _, plat := range want {
		hashByFile["burrowee-gateway-"+plat+".zip"] = "hash"
	}
	got, err := zipsFromSums("gateway", hashByFile)
	if err != nil {
		t.Fatalf("zipsFromSums: %v", err)
	}
	if len(got) != len(want) {
		t.Fatalf("want %d zips, got %d: %v", len(want), len(got), got)
	}
}

// writeStageFixture writes a minimal stage directory for comp: the four base
// platform zips (burrowee-<comp>-<plat>.zip), a SHA256SUMS.txt listing each
// zip's real sha256, and a placeholder SHA256SUMS.txt.minisig — the trio
// PublishFromDir needs to run zipsFromSums and the upload loops end to end.
func writeStageFixture(t *testing.T, dir, comp string) {
	t.Helper()
	var sums strings.Builder
	for _, plat := range basePlatforms {
		name := "burrowee-" + comp + "-" + plat + ".zip"
		body := "ZIP-" + plat
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		h := sha256.Sum256([]byte(body))
		fmt.Fprintf(&sums, "%s  %s\n", hex.EncodeToString(h[:]), name)
	}
	if err := os.WriteFile(filepath.Join(dir, "SHA256SUMS.txt"), []byte(sums.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "SHA256SUMS.txt.minisig"), []byte("SIG"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestPublishFromDirBetaUsesBetaPrefix(t *testing.T) {
	dir := t.TempDir()
	writeStageFixture(t, dir, "edge") // helper already used by this file's tests

	p := &fakePutter{}
	err := PublishFromDir(context.Background(), p, "edge", "beta", dir,
		"v0.2.21.beta.2026.08.28.716c7ede", io.Discard)
	if err != nil {
		t.Fatalf("PublishFromDir: %v", err)
	}
	for key := range p.put {
		if !strings.HasPrefix(key, "edge/beta/") {
			t.Errorf("beta publish wrote outside the beta prefix: %s", key)
		}
	}
	if _, ok := p.put["edge/beta/latest.json"]; !ok {
		t.Error("beta publish did not write edge/beta/latest.json")
	}
}

func TestPublishFromDirStablePrefixUnchanged(t *testing.T) {
	dir := t.TempDir()
	writeStageFixture(t, dir, "edge")

	p := &fakePutter{}
	err := PublishFromDir(context.Background(), p, "edge", "stable", dir,
		"v0.2.19.2026.08.27.716c7ede", io.Discard)
	if err != nil {
		t.Fatalf("PublishFromDir: %v", err)
	}
	for key := range p.put {
		if strings.Contains(key, "/beta/") {
			t.Errorf("stable publish wrote under a beta prefix: %s", key)
		}
	}
	if _, ok := p.put["edge/latest.json"]; !ok {
		t.Error("stable publish did not write edge/latest.json")
	}
}
