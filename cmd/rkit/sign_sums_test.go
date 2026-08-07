package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The tag-binding format itself is pinned in trusted_comment_test.go, which
// executes the real verifier line out of tools/bootstrap.template.sh instead of
// restating `burrowee $COMP ${TAG#*/}` as a Go literal here — a restatement
// agrees with itself no matter what the template says.

// TestSignSumsStampsTrustedComment proves a real `rkit build` signature carries
// the version stamp, not minisign's default `timestamp:… file:…` comment.
// Pre-fix, rkit signed via release-kit's minisign.Sign (no -t), so every
// rkit-cut release would be rejected by the bootstrap's tag binding.
func TestSignSumsStampsTrustedComment(t *testing.T) {
	if _, err := exec.LookPath("minisign"); err != nil {
		t.Skip("minisign not on PATH")
	}
	dir := t.TempDir()
	pub := filepath.Join(dir, "test.pub")
	key := filepath.Join(dir, "test.key")
	// -W: password-less key, the shape automated release signing uses.
	if out, err := exec.Command("minisign", "-G", "-p", pub, "-s", key, "-W").CombinedOutput(); err != nil {
		t.Fatalf("minisign -G: %v\n%s", err, out)
	}

	sums := filepath.Join(dir, "SHA256SUMS.txt")
	if err := os.WriteFile(sums, []byte("deadbeef  burrowee-cli-darwin-arm64.zip\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	const comp, stamp = "cli", "v0.1.65.2026.07.23.55e631a5"
	if err := signSums(context.Background(), sums, key, comp, stamp); err != nil {
		t.Fatalf("signSums: %v", err)
	}

	sig, err := os.ReadFile(sums + ".minisig")
	if err != nil {
		t.Fatalf("read minisig: %v", err)
	}
	want := "trusted comment: " + trustedComment(comp, stamp)
	if !strings.Contains(string(sig), want) {
		t.Fatalf("minisig missing %q; got:\n%s", want, sig)
	}

	// The comment must also survive verification (it is signed, not decorative).
	out, err := exec.Command("minisign", "-V", "-p", pub, "-m", sums).CombinedOutput()
	if err != nil {
		t.Fatalf("minisign -V: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "Trusted comment: "+trustedComment(comp, stamp)) {
		t.Fatalf("verify output missing the trusted comment; got:\n%s", out)
	}
}
