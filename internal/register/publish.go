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
	"path"
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

// Publish uploads comp's public binaries to R2 under <comp>/<version>/.
// version "" uses the current-public row. comp "relay" is refused (private).
func Publish(ctx context.Context, d PublishDeps, comp, version string) error {
	if comp == "relay" {
		return fmt.Errorf("publish: relay is private and is never pushed to R2")
	}
	row, err := fetchCatalogRow(d, comp, version)
	if err != nil {
		return err
	}
	if row.Version == "" {
		return fmt.Errorf("publish: %s: empty version in catalog", comp)
	}

	// Binaries (sha256-verified).
	for plat, a := range row.Artifacts {
		body, err := download(d.HTTP, a.URLOrKey)
		if err != nil {
			return fmt.Errorf("publish: %s/%s: %w", comp, plat, err)
		}
		sum := sha256.Sum256(body)
		if got := hex.EncodeToString(sum[:]); got != a.Sha256 {
			return fmt.Errorf("publish: %s/%s: sha256 mismatch (catalog %s, got %s)", comp, plat, a.Sha256, got)
		}
		key := comp + "/" + row.Version + "/" + baseName(a.URLOrKey)
		if err := d.R2.Put(ctx, key, body, "application/zip"); err != nil {
			return err
		}
		fmt.Printf("✓ %s\n", key)
	}

	// SHA256SUMS.txt + .minisig (no per-file catalog hash; uploaded as fetched).
	for _, ref := range []struct{ url, ctype string }{
		{row.SumsRef, "text/plain; charset=utf-8"},
		{row.MinisigRef, "application/octet-stream"},
	} {
		if ref.url == "" {
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
		fmt.Printf("✓ %s\n", key)
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
