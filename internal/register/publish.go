package register

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"sort"
	"strings"
)

// Putter uploads an object to R2. Satisfied by *r2.Client.
type Putter interface {
	Put(ctx context.Context, key string, body []byte, contentType string) error
}

// Getter performs an HTTP GET. Satisfied by *http.Client.
type Getter interface {
	Get(url string) (*http.Response, error)
}

// PublishDeps are the collaborators Publish needs (injected for tests).
type PublishDeps struct {
	ConsoleURL string
	HTTP       Getter
	R2         Putter
	// Out receives progress lines ("✓ <key>", "⚠ …"). Defaults to io.Discard when nil.
	Out io.Writer
}

func (d PublishDeps) out() io.Writer {
	if d.Out != nil {
		return d.Out
	}
	return io.Discard
}

// Body-size caps for host-side fetches. The catalog/asset URLs come from the
// console response (a network input), so an oversized/hostile body could OOM the
// release host without these. Generous-but-finite; a real release zip is tens of
// MB and a catalog body is small.
const (
	maxAssetBytes   = 512 << 20 // 512 MiB per release asset
	maxCatalogBytes = 4 << 20   // 4 MiB per catalog JSON body
)

type artifactEntry struct {
	URLOrKey string `json:"url_or_key"`
	Sha256   string `json:"sha256"`
	Size     int64  `json:"size"`
}

type catalogRow struct {
	Version    string                   `json:"version"`
	Artifacts  map[string]artifactEntry `json:"artifacts"`
	SumsRef    string                   `json:"sums_ref"`
	MinisigRef string                   `json:"minisig_ref"`
}

// zipFilename returns the platform zip's name inside a component's local
// build directory. relay's is legacy-shaped (latest.<plat>.zip, no component
// name — it predates the other components' naming and nothing depends on
// changing it); every other component's is burrowee-<comp>-<plat>.zip.
func zipFilename(comp, plat string) string {
	if comp == "relay" {
		return "latest." + plat + ".zip"
	}
	return "burrowee-" + comp + "-" + plat + ".zip"
}

// basePlatforms are the platforms every component ships on every channel. They
// are a FLOOR, not the list to upload: components may carry additional
// platforms (darwin-amd64-legacy, tools/release.sh's fifth TARGETS entry) and
// are not required to carry them uniformly — relay deliberately has no legacy
// build. See zipsFromSums.
var basePlatforms = []string{"darwin-amd64", "darwin-arm64", "linux-amd64", "linux-arm64"}

// isPlatformToken reports whether s is a bare platform token: lowercase
// alphanumerics and interior hyphens, nothing else. "darwin-amd64-legacy" is
// the longest real one.
//
// This is the boundary check on SHA256SUMS.txt. zipsFromSums derives filenames
// from that file's CONTENT and they become both an os.ReadFile path and an R2
// object key, so without it a crafted line decides where publish-dir reads and
// what it writes. Anchoring the prefix and suffix is not enough on its own:
// "burrowee-gateway-" + "../../x" + ".zip" satisfies both. In the real cut flow
// the file is generated moments earlier by the same script, so this is not a
// reachable exploit — escaping needs someone who already controls the directory
// being published, and they could simply swap the zips. It is a trust-boundary
// check, not a patch for a live hole: PublishFromDir reads SHA256SUMS.txt
// straight off disk and does NOT verify the .minisig beside it, so the file is
// trusted by location alone, and content trusted by location deserves a shape
// check before it becomes a path.
func isPlatformToken(s string) bool {
	if s == "" || strings.HasPrefix(s, "-") || strings.HasSuffix(s, "-") {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-':
		default:
			return false
		}
	}
	return true
}

// zipsFromSums returns comp's platform zip filenames, sorted, taken from the
// parsed SHA256SUMS.txt rather than from a platform list held here.
//
// It used to be a literal four-entry list, and that is precisely how the first
// beta cut shipped a broken install: tools/release.sh's TARGETS grew a fifth
// platform (darwin-amd64-legacy) and this list did not, so the R2 upload
// published four zips while the register payload — built from the actual dist
// contents — advertised five. The console then minted a presigned URL for an
// object that had never been uploaded, and every legacy Mac got a 404 from a
// release that reported success. tools/release.sh's assert_platform_coverage
// does not catch it: that guards distribute_only()'s GitHub path, not this one.
//
// SHA256SUMS.txt is the right source because it is generated from what was
// actually built, so "what was built" and "what is uploaded" cannot drift apart
// again — a sixth platform needs no change here. basePlatforms remains a floor
// so a catastrophically short build is refused rather than published quietly.
//
// It is trusted by LOCATION, not by signature: this function reads it off disk
// and never verifies the .minisig it uploads beside it. Hence isPlatformToken —
// every filename taken from it becomes a read path and an R2 key, so its shape
// is checked before it is used as either.
func zipsFromSums(comp string, hashByFile map[string]string) ([]string, error) {
	prefix, suffix := "burrowee-"+comp+"-", ".zip"
	if comp == "relay" {
		prefix = "latest."
	}
	var names []string
	seen := map[string]bool{}
	for filename := range hashByFile {
		if !strings.HasPrefix(filename, prefix) || !strings.HasSuffix(filename, suffix) {
			continue
		}
		plat := strings.TrimSuffix(strings.TrimPrefix(filename, prefix), suffix)
		if !isPlatformToken(plat) {
			return nil, fmt.Errorf("publish-dir: %s: SHA256SUMS.txt names %q, whose platform segment %q is not a bare [a-z0-9-] token — refusing",
				comp, filename, plat)
		}
		names = append(names, filename)
		seen[plat] = true
	}
	var missing []string
	for _, plat := range basePlatforms {
		if !seen[plat] {
			missing = append(missing, plat)
		}
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("publish-dir: %s: SHA256SUMS.txt is missing platform(s) %s — refusing to publish a short build",
			comp, strings.Join(missing, ", "))
	}
	sort.Strings(names)
	return names, nil
}

// PublishFromDir uploads a component's artifacts from a local directory to R2
// under <comp>/<stamp>/. It uploads every platform zip SHA256SUMS.txt lists
// (see zipsFromSums), SHA256SUMS.txt, and SHA256SUMS.txt.minisig found in dir.
// Size+sha256 are verified against SHA256SUMS.txt before upload.
//
// relay was the first (and, before beta, only) private component, so this was
// written for it and driven by the relay cut flow (do_release_relay in
// release.sh), which produces local artifacts instead of publishing a GitHub
// Release. A beta cut of any component is private the same way until
// promoted (spec §5.3), so this now takes comp and is used by all five. The
// catalog/console-side row's url_or_key/sums_ref/minisig_ref already point at
// the matching R2 keys <comp>/<stamp>/... before this function runs.
//
// Integrity is gated by sha256 of each file against the minisign-signed
// SHA256SUMS.txt; there is no catalog size reference on the local-upload path,
// so size-from-catalog verification (as in Publish) does not apply here.
func PublishFromDir(ctx context.Context, r2 Putter, comp, dir, stamp string, out io.Writer) error {
	if out == nil {
		out = io.Discard
	}
	sumsPath := dir + "/SHA256SUMS.txt"
	sumsBody, err := os.ReadFile(sumsPath)
	if err != nil {
		return fmt.Errorf("publish-dir: read SHA256SUMS.txt: %w", err)
	}
	// parse SHA256SUMS.txt: each line is "<hex>  <filename>"
	hashByFile := map[string]string{}
	for _, line := range strings.Split(string(sumsBody), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		hashByFile[fields[1]] = fields[0]
	}

	// Every platform zip SHA256SUMS.txt lists, verified in full BEFORE anything
	// is uploaded. Verifying inside the upload loop would leave a mismatch
	// partially published — the zips that happened to sort earlier are already
	// in R2 when the bad one aborts, so a half-written version is visible to
	// the presigner while the cut reports failure. The split makes the "abort
	// uploads nothing" guarantee hold for a mismatch on ANY platform rather
	// than only on whichever one the iteration order happens to reach first.
	filenames, err := zipsFromSums(comp, hashByFile)
	if err != nil {
		return err
	}
	verified := make([][]byte, len(filenames))
	for i, filename := range filenames {
		body, err := os.ReadFile(dir + "/" + filename)
		if err != nil {
			return fmt.Errorf("publish-dir: read %s: %w", filename, err)
		}
		expectedHash, ok := hashByFile[filename]
		if !ok {
			return fmt.Errorf("publish-dir: %s not found in SHA256SUMS.txt", filename)
		}
		sum := sha256.Sum256(body)
		if got := hex.EncodeToString(sum[:]); got != expectedHash {
			return fmt.Errorf("publish-dir: %s: sha256 mismatch (sums %s, got %s)", filename, expectedHash, got)
		}
		verified[i] = body
	}
	for i, filename := range filenames {
		key := comp + "/" + stamp + "/" + filename
		if err := r2.Put(ctx, key, verified[i], "application/zip"); err != nil {
			return err
		}
		fmt.Fprintf(out, "✓ %s\n", key)
	}

	// Upload SHA256SUMS.txt + .minisig (no hash verification needed — sums file is self-referential).
	for _, entry := range []struct {
		filename    string
		contentType string
	}{
		{"SHA256SUMS.txt", "text/plain; charset=utf-8"},
		{"SHA256SUMS.txt.minisig", "application/octet-stream"},
	} {
		body, err := os.ReadFile(dir + "/" + entry.filename)
		if err != nil {
			return fmt.Errorf("publish-dir: read %s: %w", entry.filename, err)
		}
		key := comp + "/" + stamp + "/" + entry.filename
		if err := r2.Put(ctx, key, body, entry.contentType); err != nil {
			return err
		}
		fmt.Fprintf(out, "✓ %s\n", key)
	}
	return nil
}

// Publish uploads comp's public binaries to R2 under <comp>/<version>/.
// version "" uses the current-public row.
func Publish(ctx context.Context, d PublishDeps, comp, version string) error {
	row, err := fetchCatalogRow(d, comp, version)
	if err != nil {
		return err
	}
	if row.Version == "" {
		return fmt.Errorf("publish: %s: empty version in catalog", comp)
	}

	// Binaries (size + sha256 verified). Upload in deterministic platform order.
	plats := make([]string, 0, len(row.Artifacts))
	for plat := range row.Artifacts {
		plats = append(plats, plat)
	}
	sort.Strings(plats)

	for _, plat := range plats {
		a := row.Artifacts[plat]
		body, err := download(d.HTTP, a.URLOrKey)
		if err != nil {
			return fmt.Errorf("publish: %s/%s: %w", comp, plat, err)
		}
		// Size cross-check (belt-and-suspenders; sha256 below is the hard gate).
		if a.Size > 0 && int64(len(body)) != a.Size {
			return fmt.Errorf("publish: %s/%s: size mismatch (catalog %d, got %d)", comp, plat, a.Size, len(body))
		}
		sum := sha256.Sum256(body)
		if got := hex.EncodeToString(sum[:]); got != a.Sha256 {
			return fmt.Errorf("publish: %s/%s: sha256 mismatch (catalog %s, got %s)", comp, plat, a.Sha256, got)
		}
		key := comp + "/" + row.Version + "/" + baseName(a.URLOrKey)
		if err := d.R2.Put(ctx, key, body, "application/zip"); err != nil {
			return err
		}
		fmt.Fprintf(d.out(), "✓ %s\n", key)
	}

	// SHA256SUMS.txt + .minisig (no per-file catalog hash; uploaded as fetched).
	for _, ref := range []struct{ url, ctype, label string }{
		{row.SumsRef, "text/plain; charset=utf-8", "sums_ref"},
		{row.MinisigRef, "application/octet-stream", "minisig_ref"},
	} {
		if ref.url == "" {
			fmt.Fprintf(d.out(), "⚠ %s %s: empty ref, skipping\n", comp, ref.label)
			continue
		}
		body, err := download(d.HTTP, ref.url)
		if err != nil {
			return fmt.Errorf("publish: %s: %w", comp, err)
		}
		key := comp + "/" + row.Version + "/" + baseName(ref.url)
		if err := d.R2.Put(ctx, key, body, ref.ctype); err != nil {
			return err
		}
		fmt.Fprintf(d.out(), "✓ %s\n", key)
	}
	return nil
}

func fetchCatalogRow(d PublishDeps, comp, version string) (catalogRow, error) {
	var zero catalogRow
	if version == "" {
		var row catalogRow
		if err := getJSON(d.HTTP, d.ConsoleURL+"/api/v1/releases/"+comp+"/current", &row); err != nil {
			return zero, err
		}
		return row, nil
	}
	var rows []catalogRow
	if err := getJSON(d.HTTP, d.ConsoleURL+"/api/v1/releases/"+comp, &rows); err != nil {
		return zero, err
	}
	for _, r := range rows {
		if r.Version == version {
			return r, nil
		}
	}
	return zero, fmt.Errorf("publish: %s: version %s not found among public releases", comp, version)
}

func getJSON(h Getter, rawURL string, out any) error {
	resp, err := h.Get(rawURL)
	if err != nil {
		return fmt.Errorf("GET %s: %w", rawURL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, resp.Body)
		return fmt.Errorf("GET %s: status %d", rawURL, resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, maxCatalogBytes)).Decode(out)
}

func download(h Getter, rawurl string) ([]byte, error) {
	resp, err := h.Get(rawurl)
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", rawurl, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil, fmt.Errorf("GET %s: status %d", rawurl, resp.StatusCode)
	}
	// Cap the read so a hostile/oversized asset can't OOM the release host.
	// Read one byte past the limit to distinguish "exactly at cap" from "over".
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxAssetBytes+1))
	if err != nil {
		return nil, fmt.Errorf("GET %s: read body: %w", rawurl, err)
	}
	if int64(len(body)) > maxAssetBytes {
		return nil, fmt.Errorf("GET %s: asset exceeds %d-byte cap", rawurl, int64(maxAssetBytes))
	}
	return body, nil
}

func baseName(rawurl string) string {
	if u, err := url.Parse(rawurl); err == nil && u.Path != "" {
		return path.Base(u.Path)
	}
	return path.Base(rawurl)
}
