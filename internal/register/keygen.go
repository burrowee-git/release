package register

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
)

// Keygen generates a fresh Ed25519 keypair under dir, writing:
//
//   - client.key  — base64(private key, 64 bytes), mode 0600
//   - client.pub  — base64(public key, 32 bytes), mode 0644
//
// It returns the base64-encoded public key.
func Keygen(dir string) (pubB64 string, err error) {
	if err = os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("mkdir %s: %w", dir, err)
	}

	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", fmt.Errorf("generate key: %w", err)
	}

	privB64 := base64.StdEncoding.EncodeToString(priv)
	pubB64 = base64.StdEncoding.EncodeToString(pub)

	keyPath := filepath.Join(dir, "client.key")
	if err = os.WriteFile(keyPath, []byte(privB64+"\n"), 0o600); err != nil {
		return "", fmt.Errorf("write client.key: %w", err)
	}

	pubPath := filepath.Join(dir, "client.pub")
	if err = os.WriteFile(pubPath, []byte(pubB64+"\n"), 0o644); err != nil {
		return "", fmt.Errorf("write client.pub: %w", err)
	}

	return pubB64, nil
}
