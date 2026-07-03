package gate

import (
	"crypto/ed25519"
	"testing"
)

func TestFingerprint(t *testing.T) {
	pub := ed25519.PublicKey(make([]byte, 32)) // all-zero pubkey

	// Anchor: sha256(32×0x00) → hex → first 16 chars.
	const wantAnchor = "66687aadf862bd77"
	if got := Fingerprint(pub); got != wantAnchor {
		t.Fatalf("Fingerprint = %q want %q", got, wantAnchor)
	}
	if len(Fingerprint(pub)) != 16 {
		t.Fatalf("fingerprint must be 16 hex chars")
	}
}
