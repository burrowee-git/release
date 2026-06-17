package gate

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
)

// Fingerprint returns hex(sha256(raw pubkey))[:16] — the registry key and
// the X-Burrowee-Key-FP header value. Exactly 16 lowercase hex characters.
// The raw 32-byte pubkey (not PEM, not DER) is the hash input; this must be
// computed identically by the register script (openssl) and relay install.sh.
func Fingerprint(pub ed25519.PublicKey) string {
	sum := sha256.Sum256(pub)
	return hex.EncodeToString(sum[:])[:16]
}
