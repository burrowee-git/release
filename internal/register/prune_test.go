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
	n, err := Prune(context.Background(), store, "relay", "stable", true, io.Discard)
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
		// Full §4.1 stamp shape (date+sha) so chOf's shape validation matches
		// it; patch number i (not the date/sha suffix) drives ordering, and
		// i runs past 9 so plain lexical order would disagree with numeric
		// order — proving the version comparator, not string order, decides.
		versions = append(versions, "v0.1."+itoa(i)+".2026.06."+pad2(i)+"."+hex8(i))
	}
	var keys []string
	for _, v := range versions {
		keys = append(keys, "cli/"+v+"/burrowee-cli-darwin-arm64.zip")
	}
	store := &fakeStore{keys: keys}
	n, err := Prune(context.Background(), store, "cli", "stable", true, io.Discard)
	if err != nil {
		t.Fatalf("Prune: %v", err)
	}
	// 13 versions → keep 10 → drop 3 oldest (v0.1.1, v0.1.2, v0.1.3), 1 object each.
	if n != 3 {
		t.Errorf("deleted count: got %d want 3", n)
	}
	want := map[string]bool{
		"cli/" + versions[0] + "/burrowee-cli-darwin-arm64.zip": true,
		"cli/" + versions[1] + "/burrowee-cli-darwin-arm64.zip": true,
		"cli/" + versions[2] + "/burrowee-cli-darwin-arm64.zip": true,
	}
	for _, k := range store.deleted {
		if !want[k] {
			t.Errorf("deleted unexpected key: %s", k)
		}
	}
	if len(store.deleted) != len(want) {
		t.Errorf("deleted %d objects, want exactly %d: %v", len(store.deleted), len(want), store.deleted)
	}
}

// TestPruneChannelsNeverMix is the guard on the destructive part of spec
// §5.5: a stable prune must never count or delete a beta version, and a beta
// prune must never count or delete a stable one, even though both channels'
// keys sit side by side under the same <comp>/ prefix in R2.
func TestPruneChannelsNeverMix(t *testing.T) {
	var stable, beta []string
	for i := 1; i <= 12; i++ {
		stable = append(stable, "cli/v0.1."+itoa(i)+".2026.06."+pad2(i)+"."+hex8(i)+"/burrowee-cli-darwin-arm64.zip")
	}
	for i := 1; i <= 7; i++ {
		beta = append(beta, "cli/v0.2."+itoa(i)+".beta.2026.07."+pad2(i)+"."+hex8(i)+"/burrowee-cli-darwin-arm64.zip")
	}
	keys := append(append([]string(nil), stable...), beta...)

	stableStore := &fakeStore{keys: keys}
	n, err := Prune(context.Background(), stableStore, "cli", "stable", true, io.Discard)
	if err != nil {
		t.Fatalf("Prune stable: %v", err)
	}
	if n != 2 {
		t.Errorf("stable deleted count: got %d want 2", n)
	}
	// 12 stable → keep 10 → drop the 2 oldest (stable[0], stable[1]) — pinned
	// exactly, not just "no beta key showed up", per TestPrunePublicKeepsTen's
	// sibling style: on a destructive path "the oldest 2" should be explicit.
	wantStable := map[string]bool{stable[0]: true, stable[1]: true}
	for _, k := range stableStore.deleted {
		if !wantStable[k] {
			t.Errorf("stable prune deleted unexpected key: %s", k)
		}
	}
	if len(stableStore.deleted) != len(wantStable) {
		t.Errorf("stable prune deleted %d objects, want exactly %d: %v", len(stableStore.deleted), len(wantStable), stableStore.deleted)
	}

	betaStore := &fakeStore{keys: keys}
	n, err = Prune(context.Background(), betaStore, "cli", "beta", true, io.Discard)
	if err != nil {
		t.Fatalf("Prune beta: %v", err)
	}
	if n != 2 {
		t.Errorf("beta deleted count: got %d want 2", n)
	}
	// 7 beta → keep 5 → drop the 2 oldest (beta[0], beta[1]).
	wantBeta := map[string]bool{beta[0]: true, beta[1]: true}
	for _, k := range betaStore.deleted {
		if !wantBeta[k] {
			t.Errorf("beta prune deleted unexpected key: %s", k)
		}
	}
	if len(betaStore.deleted) != len(wantBeta) {
		t.Errorf("beta prune deleted %d objects, want exactly %d: %v", len(betaStore.deleted), len(wantBeta), betaStore.deleted)
	}
}

// TestPruneNeverCountsANonConformingKey is the guard on spec §4.1's "a tag
// matching neither [channel pattern] is ignored — everywhere": a version that
// matches neither the stable nor the beta shape (a legacy directory, a manual
// upload, a typo'd stamp) must never be counted toward either channel's
// keepFor budget, and must never be deleted by either channel's prune.
//
// nonConforming has no date/sha suffix at all, so it matches neither §4.1
// pattern. It sorts before every well-formed version below (its second
// version-number field is "0" vs their "1", and verrevcmp's digit-run
// comparison decides on that difference alone) — so a classifier that
// mislabels it "stable" on a bare ".beta." substring probe would count it as
// the very oldest "stable" entry and DELETE it once keep=3 forces a drop.
// Pinning that it survives (and that only the true oldest well-formed
// version is dropped) proves the shape check gates deletion, not just
// classification.
func TestPruneNeverCountsANonConformingKey(t *testing.T) {
	wellFormed := []string{
		"relay/v0.1.1.2026.06.01.aaaaaaaa/latest.darwin-arm64.zip",
		"relay/v0.1.2.2026.06.02.bbbbbbbb/latest.darwin-arm64.zip",
		"relay/v0.1.3.2026.06.03.cccccccc/latest.darwin-arm64.zip",
		"relay/v0.1.4.2026.06.04.dddddddd/latest.darwin-arm64.zip",
	}
	nonConforming := "relay/v0.0.1-legacy/latest.darwin-arm64.zip"
	keys := append(append([]string(nil), wellFormed...), nonConforming)

	stableStore := &fakeStore{keys: keys}
	n, err := Prune(context.Background(), stableStore, "relay", "stable", true, io.Discard)
	if err != nil {
		t.Fatalf("Prune stable: %v", err)
	}
	// 4 well-formed → keep 3 (relay) → drop only the oldest well-formed
	// version. The non-conforming key must never be counted in, so this is 1,
	// not 2.
	if n != 1 {
		t.Errorf("stable deleted count: got %d want 1", n)
	}
	if len(stableStore.deleted) != 1 || stableStore.deleted[0] != wellFormed[0] {
		t.Errorf("stable prune deleted %v, want exactly [%q]", stableStore.deleted, wellFormed[0])
	}
	for _, k := range stableStore.deleted {
		if k == nonConforming {
			t.Errorf("stable prune deleted the non-conforming key: %s", k)
		}
	}

	betaStore := &fakeStore{keys: keys}
	n, err = Prune(context.Background(), betaStore, "relay", "beta", true, io.Discard)
	if err != nil {
		t.Fatalf("Prune beta: %v", err)
	}
	if n != 0 {
		t.Errorf("beta deleted count: got %d want 0 (no beta-shaped keys present)", n)
	}
	for _, k := range betaStore.deleted {
		if k == nonConforming {
			t.Errorf("beta prune deleted the non-conforming key: %s", k)
		}
	}
}

// pad2 zero-pads i to 2 digits (day-of-month position in the stamp).
func pad2(i int) string {
	if i < 10 {
		return "0" + itoa(i)
	}
	return itoa(i)
}

// hex8 renders i as an 8-hex-digit sha stand-in, distinct per i.
func hex8(i int) string {
	s := itoa(i)
	return strings.Repeat("0", 8-len(s)) + s
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
	n, err := Prune(context.Background(), store, "relay", "stable", false, &buf)
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
	n, err := Prune(context.Background(), store, "relay", "stable", true, io.Discard)
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
