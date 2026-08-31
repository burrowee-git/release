package register

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

type fakePutter struct{ put map[string][]byte }

func (f *fakePutter) Put(_ context.Context, key string, body []byte, _ string) error {
	if f.put == nil {
		f.put = map[string][]byte{}
	}
	f.put[key] = body
	return nil
}

func TestWriteLatestStableKeyAndBody(t *testing.T) {
	p := &fakePutter{}
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	zips := []string{"burrowee-edge-linux-amd64.zip", "burrowee-edge-darwin-arm64.zip"}

	err := WriteLatest(context.Background(), p, "edge", "stable",
		"v0.2.19.2026.08.27.716c7ede", "0.2.19", zips, now)
	if err != nil {
		t.Fatalf("WriteLatest: %v", err)
	}

	body, ok := p.put["edge/latest.json"]
	if !ok {
		t.Fatalf("no object at edge/latest.json; got keys %v", keysOf(p))
	}
	var m LatestManifest
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatalf("manifest is not valid JSON: %v", err)
	}
	if m.Path != "edge/v0.2.19.2026.08.27.716c7ede" {
		t.Errorf("Path = %q, want edge/v0.2.19.2026.08.27.716c7ede", m.Path)
	}
	if m.SHA256Sums != m.Path+"/SHA256SUMS.txt" {
		t.Errorf("SHA256Sums = %q, want %q", m.SHA256Sums, m.Path+"/SHA256SUMS.txt")
	}
	if m.Minisig != m.Path+"/SHA256SUMS.txt.minisig" {
		t.Errorf("Minisig = %q", m.Minisig)
	}
	if m.Updated != "2026-08-31T12:00:00Z" {
		t.Errorf("Updated = %q, want 2026-08-31T12:00:00Z", m.Updated)
	}
	// Zips must be sorted, so the encoded manifest is stable across cuts that
	// happen to read the directory in a different order.
	if m.Zips[0] != "burrowee-edge-darwin-arm64.zip" {
		t.Errorf("Zips not sorted: %v", m.Zips)
	}
}

func TestWriteLatestBetaKeyIsUnderBetaPrefix(t *testing.T) {
	p := &fakePutter{}
	err := WriteLatest(context.Background(), p, "edge", "beta",
		"v0.2.21.beta.2026.08.28.716c7ede", "0.2.21",
		[]string{"burrowee-edge-linux-amd64.zip"}, time.Now().UTC())
	if err != nil {
		t.Fatalf("WriteLatest: %v", err)
	}
	if _, ok := p.put["edge/beta/latest.json"]; !ok {
		t.Fatalf("no object at edge/beta/latest.json; got keys %v", keysOf(p))
	}
	if _, ok := p.put["edge/latest.json"]; ok {
		t.Fatal("a beta cut wrote the STABLE manifest — it would advertise a beta build to stable installs")
	}
	var m LatestManifest
	_ = json.Unmarshal(p.put["edge/beta/latest.json"], &m)
	if !strings.HasPrefix(m.Path, "edge/beta/") {
		t.Errorf("beta manifest Path = %q, want an edge/beta/ prefix", m.Path)
	}
}

func TestWriteLatestRejectsNoZips(t *testing.T) {
	p := &fakePutter{}
	err := WriteLatest(context.Background(), p, "edge", "stable",
		"v0.2.19.2026.08.27.716c7ede", "0.2.19", nil, time.Now().UTC())
	if err == nil {
		t.Fatal("a manifest naming zero artifacts must be refused, not published")
	}
}

func keysOf(p *fakePutter) []string {
	var out []string
	for k := range p.put {
		out = append(out, k)
	}
	return out
}
