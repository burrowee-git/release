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

// PublishFromDir uploads the relay artifacts from a local directory to R2 under
// relay/<stamp>/. It uploads every latest.<os>-<arch>.zip, SHA256SUMS.txt, and
// SHA256SUMS.txt.minisig found in dir. Size+sha256 are verified against
// SHA256SUMS.txt before upload.
//
// This is used by the relay cut flow (do_release_relay in release.sh) which
// produces local artifacts instead of publishing a GitHub Release. The catalog
// row's url_or_key/sums_ref/minisig_ref already point at the R2 keys
// relay/<stamp>/... before this function runs.
func PublishFromDir(ctx context.Context, r2 Putter, dir, stamp string, out io.Writer) error {
	if out == nil {
		out = io.Discard
	}
	sumsPath := dir + "/SHA256SUMS.txt"
	sumsBody, err := os.ReadFile(sumsPath)
	if err != nil {
		return fmt.Errorf("publish-relay: read SHA256SUMS.txt: %w", err)
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

	// Upload the four platform zips with sha256 verification.
	platforms := []string{"darwin-arm64", "darwin-amd64", "linux-arm64", "linux-amd64"}
	for _, plat := range platforms {
		filename := "latest." + plat + ".zip"
		body, err := os.ReadFile(dir + "/" + filename)
		if err != nil {
			return fmt.Errorf("publish-relay: read %s: %w", filename, err)
		}
		expectedHash, ok := hashByFile[filename]
		if !ok {
			return fmt.Errorf("publish-relay: %s not found in SHA256SUMS.txt", filename)
		}
		sum := sha256.Sum256(body)
		if got := hex.EncodeToString(sum[:]); got != expectedHash {
			return fmt.Errorf("publish-relay: %s: sha256 mismatch (sums %s, got %s)", filename, expectedHash, got)
		}
		key := "relay/" + stamp + "/" + filename
		if err := r2.Put(ctx, key, body, "application/zip"); err != nil {
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
			return fmt.Errorf("publish-relay: read %s: %w", entry.filename, err)
		}
		key := "relay/" + stamp + "/" + entry.filename
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
	return json.NewDecoder(resp.Body).Decode(out)
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
	return io.ReadAll(resp.Body)
}

func baseName(rawurl string) string {
	if u, err := url.Parse(rawurl); err == nil && u.Path != "" {
		return path.Base(u.Path)
	}
	return path.Base(rawurl)
}
