package shelllint

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// rootSecureContractBegin / rootSecureContractEnd delimit the ROOT-SECURE
// CONTRACT region: the stat-dialect probe, stat_uid / stat_mode,
// mode_allows_nonroot_write, path_is_root_secure and dir_is_root_secure — the
// shell half of core/binary's IsRootSecure / IsRootSecureDir.
//
// The region is DUPLICATED, byte for byte, in every inner installer that
// creates a machine-owned tree, rather than sourced from a shared file. Three
// reasons, each of which rules out a shared library on its own:
//
//   - the assertion must run even when a bundle carries no migrations/ dir —
//     BURROWEE_UNITS_ONLY runs from a self-copy that may predate it, so a
//     sourced lib would need an inline fallback that IS the second copy;
//   - the gateway does not take the shared ladder (tools/payload.sh's
//     takes_shared_ladder = edge|cli|relay), so inner/_shared is not in a
//     gateway kit at all;
//   - the repo already guards a duplicated region this way — the SHARED SWEEP
//     CONTRACT in lib_stale_user_bins.sh, byte-compared by
//     tools/test-shared-migrations.sh.
//
// The relay's inner installer lives in the relay repo and carries the same
// region; that repo pins it against the gateway copy the same way.
const (
	rootSecureContractBegin = "# === ROOT-SECURE CONTRACT BEGIN ==="
	rootSecureContractEnd   = "# === ROOT-SECURE CONTRACT END ==="
)

// rootSecureContractCarriers are the installers in THIS repo that carry the
// region. Every one of them creates or verifies a root-owned tree and must
// answer "is this directory root-secure" with the identical predicate.
var rootSecureContractCarriers = []string{
	"inner/gateway/install.sh",
	"inner/edge/install.sh",
}

// rootSecureContractRegion returns the region between the two sentinels,
// sentinel lines included, and fails when either sentinel is missing — a region
// that came out empty would compare equal to another empty region.
func rootSecureContractRegion(t *testing.T, path string) []byte {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	begin := bytes.Index(body, []byte(rootSecureContractBegin+"\n"))
	if begin < 0 {
		t.Fatalf("%s: the opening sentinel %q is missing", path, rootSecureContractBegin)
	}
	rest := body[begin:]
	end := bytes.Index(rest, []byte(rootSecureContractEnd+"\n"))
	if end < 0 {
		t.Fatalf("%s: the closing sentinel %q is missing", path, rootSecureContractEnd)
	}
	return rest[:end+len(rootSecureContractEnd)+1]
}

// TestRootSecureContractIsByteIdenticalInBothInstallers pins the two copies to
// each other. Editing one reddens this until the other receives the same edit;
// there is no digest to update, because both copies live in this repo.
//
// The region is also required to carry both predicates: a sentinel pair that
// fenced off an empty stretch, or one that fenced only the file form, would
// compare equal in both files and guard nothing.
func TestRootSecureContractIsByteIdenticalInBothInstallers(t *testing.T) {
	root := repoRoot(t)
	reference := rootSecureContractRegion(t, filepath.Join(root, rootSecureContractCarriers[0]))
	for _, want := range []string{
		"path_is_root_secure() {",
		"dir_is_root_secure() {",
		"mode_allows_nonroot_write() {",
		"stat_uid() {",
		"stat_mode() {",
	} {
		if !bytes.Contains(reference, []byte(want+"\n")) {
			t.Errorf("%s: the ROOT-SECURE CONTRACT region does not define %q — the sentinels fence the wrong text", rootSecureContractCarriers[0], want)
		}
	}
	for _, rel := range rootSecureContractCarriers[1:] {
		got := rootSecureContractRegion(t, filepath.Join(root, rel))
		if !bytes.Equal(got, reference) {
			t.Errorf("%s: the ROOT-SECURE CONTRACT region differs from %s's — the two copies must be byte-identical; apply the same edit to both",
				rel, rootSecureContractCarriers[0])
		}
	}
}
