package register

import (
	"context"
	"io"
	"sort"
	"strings"
	"testing"
)

// fakeStore satisfies PruneStore: List returns a fixed key set, Delete records
// what was removed.
type fakeStore struct {
	keys    []string
	deleted []string
}

func (f *fakeStore) List(_ context.Context, prefix string) ([]string, error) {
	var out []string
	for _, k := range f.keys {
		if strings.HasPrefix(k, prefix) {
			out = append(out, k)
		}
	}
	return out, nil
}

func (f *fakeStore) Delete(_ context.Context, key string) error {
	f.deleted = append(f.deleted, key)
	return nil
}

func keysFor(versions []string) []string {
	var out []string
	for _, v := range versions {
		out = append(out,
			"relay/"+v+"/latest.darwin-arm64.zip",
			"relay/"+v+"/SHA256SUMS.txt",
		)
	}
	return out
}

func TestVersionLessMatchesSortV(t *testing.T) {
	// The exact ordering `sort -V` produces for these stamps (verified against
	// the shell). versionLess must agree so newest-N matches the rest of the
	// tooling.
	in := []string{
		"v0.1.9", "v0.1.12", "v0.1.2",
		"v0.1.34.2026.06.22.2c1df31b",
		"v0.1.5.2026.06.11.5048cdba",
		"v0.1.24.2026.06.15.2abcae13",
	}
	want := []string{
		"v0.1.2",
		"v0.1.5.2026.06.11.5048cdba",
		"v0.1.9",
		"v0.1.12",
		"v0.1.24.2026.06.15.2abcae13",
		"v0.1.34.2026.06.22.2c1df31b",
	}
	got := append([]string(nil), in...)
	sort.Sort(byVersionSort(got))
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("sort mismatch:\n got: %v\nwant: %v", got, want)
		}
	}
}

func TestVersionLessShaTieBreak(t *testing.T) {
	// Stamps sharing the same vX.Y.Z triple + date, differing only in the
	// trailing 8-hex git sha. Field-wise lexical comparison gets this wrong;
	// GNU `sort -V` interleaves alpha-leading and numeric-leading shas. The
	// want order below is exactly what `sort -V` produces (verified against the
	// shell binary).
	in := []string{
		"v0.1.34.2026.06.22.0abcdef0",
		"v0.1.34.2026.06.22.abcdef00",
		"v0.1.34.2026.06.22.5048cdba",
		"v0.1.34.2026.06.22.f048cdba",
	}
	want := []string{
		"v0.1.34.2026.06.22.abcdef00",
		"v0.1.34.2026.06.22.f048cdba",
		"v0.1.34.2026.06.22.0abcdef0",
		"v0.1.34.2026.06.22.5048cdba",
	}
	got := append([]string(nil), in...)
	sort.Sort(byVersionSort(got))
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("sha tie-break mismatch:\n got: %v\nwant: %v", got, want)
		}
	}
}

func TestPruneRelayKeepsThree(t *testing.T) {
	versions := []string{
		"v0.1.1.2026.06.01.aaaaaaaa",
		"v0.1.2.2026.06.02.bbbbbbbb",
		"v0.1.3.2026.06.03.cccccccc",
		"v0.1.4.2026.06.04.dddddddd",
		"v0.1.5.2026.06.05.eeeeeeee",
	}
	store := &fakeStore{keys: keysFor(versions)}
	n, err := Prune(context.Background(), store, "relay", true, io.Discard)
	if err != nil {
		t.Fatalf("Prune: %v", err)
	}
	// 2 oldest versions dropped × 2 objects each = 4 deletions.
	if n != 4 {
		t.Errorf("deleted count: got %d want 4", n)
	}
	for _, k := range store.deleted {
		if strings.Contains(k, "v0.1.1") || strings.Contains(k, "v0.1.2") {
			continue
		}
		t.Errorf("deleted a kept version: %s", k)
	}
	if len(store.deleted) != 4 {
		t.Errorf("deleted %d objects: %v", len(store.deleted), store.deleted)
	}
}

func TestPrunePublicKeepsTen(t *testing.T) {
	var versions []string
	for i := 1; i <= 13; i++ {
		// zero-pad so plain lexical order would disagree with numeric order,
		// proving the version comparator (not string order) drives selection.
		versions = append(versions, "v0.1."+itoa(i))
	}
	var keys []string
	for _, v := range versions {
		keys = append(keys, "cli/"+v+"/burrowee-cli-darwin-arm64.zip")
	}
	store := &fakeStore{keys: keys}
	n, err := Prune(context.Background(), store, "cli", true, io.Discard)
	if err != nil {
		t.Fatalf("Prune: %v", err)
	}
	// 13 versions → keep 10 → drop 3 (v0.1.1, v0.1.2, v0.1.3), 1 object each.
	if n != 3 {
		t.Errorf("deleted count: got %d want 3", n)
	}
	want := map[string]bool{
		"cli/v0.1.1/burrowee-cli-darwin-arm64.zip": true,
		"cli/v0.1.2/burrowee-cli-darwin-arm64.zip": true,
		"cli/v0.1.3/burrowee-cli-darwin-arm64.zip": true,
	}
	for _, k := range store.deleted {
		if !want[k] {
			t.Errorf("deleted unexpected key: %s", k)
		}
	}
}

func TestPruneDryRunDeletesNothing(t *testing.T) {
	versions := []string{
		"v0.1.1.2026.06.01.aaaaaaaa",
		"v0.1.2.2026.06.02.bbbbbbbb",
		"v0.1.3.2026.06.03.cccccccc",
		"v0.1.4.2026.06.04.dddddddd",
	}
	store := &fakeStore{keys: keysFor(versions)}
	var buf strings.Builder
	n, err := Prune(context.Background(), store, "relay", false, &buf)
	if err != nil {
		t.Fatalf("Prune: %v", err)
	}
	if n != 2 {
		t.Errorf("planned count: got %d want 2", n)
	}
	if len(store.deleted) != 0 {
		t.Errorf("dry-run must not delete: %v", store.deleted)
	}
	if !strings.Contains(buf.String(), "would delete") {
		t.Errorf("dry-run output missing plan: %q", buf.String())
	}
}

func TestPruneUnderKeepIsNoOp(t *testing.T) {
	store := &fakeStore{keys: keysFor([]string{"v0.1.1.x", "v0.1.2.x"})}
	n, err := Prune(context.Background(), store, "relay", true, io.Discard)
	if err != nil {
		t.Fatalf("Prune: %v", err)
	}
	if n != 0 || len(store.deleted) != 0 {
		t.Errorf("≤ keep must be a no-op: n=%d deleted=%v", n, store.deleted)
	}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b []byte
	for i > 0 {
		b = append([]byte{byte('0' + i%10)}, b...)
		i /= 10
	}
	return string(b)
}
