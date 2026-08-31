package register

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"time"
)

// LatestManifest is the <prefix>latest.json schema — the per-channel pointer at
// the newest published stamp. Fields are declared in alphabetical order so
// json.Marshal emits them in a stable, diff-friendly order, matching the shape
// clawee's r2-mirror already writes: one reader works against either brand.
type LatestManifest struct {
	Component  string   `json:"component"`
	Minisig    string   `json:"minisig"`
	Path       string   `json:"path"`
	SHA256Sums string   `json:"sha256sums"`
	Stamp      string   `json:"stamp"`
	Updated    string   `json:"updated"`
	Version    string   `json:"version"`
	Zips       []string `json:"zips"`
}

// WriteLatest publishes comp's manifest for channel at <prefix>latest.json,
// pointing at stamp. The manifest is NOT under the stamp directory: it outlives
// every stamp it has ever named, and being outside <prefix><stamp>/ is also what
// keeps retention from treating it as a prune candidate.
//
// zips is sorted in place before encoding, so two cuts that read the stage
// directory in different orders still produce byte-identical manifests.
func WriteLatest(ctx context.Context, r2 Putter, comp, channel, stamp, semver string, zips []string, now time.Time) error {
	if len(zips) == 0 {
		return fmt.Errorf("manifest %s/%s: refusing to publish a manifest naming zero artifacts", comp, channel)
	}
	slices.Sort(zips)

	base := KeyPrefix(comp, channel) + stamp
	m := LatestManifest{
		Component:  comp,
		Minisig:    base + "/SHA256SUMS.txt.minisig",
		Path:       base,
		SHA256Sums: base + "/SHA256SUMS.txt",
		Stamp:      stamp,
		Updated:    now.UTC().Format(time.RFC3339),
		Version:    semver,
		Zips:       zips,
	}

	body, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("manifest %s/%s: encode: %w", comp, channel, err)
	}
	body = append(body, '\n')

	key := KeyPrefix(comp, channel) + "latest.json"
	if err := r2.Put(ctx, key, body, "application/json"); err != nil {
		return fmt.Errorf("manifest %s: %w", key, err)
	}
	return nil
}
