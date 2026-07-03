package gate

import (
	"crypto/ed25519"
	"database/sql"
	"errors"
	"fmt"

	_ "modernc.org/sqlite"
)

// Registry wraps a read-only sqlite pubkey store.
// Schema: pubkeys(fingerprint TEXT PRIMARY KEY, pubkey BLOB NOT NULL, label TEXT, added_at INTEGER).
// The pubkey BLOB is the raw 32-byte ed25519 public key (not PEM, not DER).
type Registry struct {
	db *sql.DB
}

// OpenRegistry opens the sqlite database at path in read-only mode.
// The caller is responsible for closing the registry when done.
func OpenRegistry(path string) (*Registry, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro")
	if err != nil {
		return nil, err
	}
	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("gate: open registry %s: %w", path, err)
	}
	return &Registry{db: db}, nil
}

// Lookup retrieves the ed25519 public key for the given fingerprint.
// Returns (pubkey, true, nil) on a hit, (nil, false, nil) on a miss,
// and (nil, false, err) on a database error.
func (r *Registry) Lookup(fp string) (ed25519.PublicKey, bool, error) {
	var raw []byte
	err := r.db.QueryRow(`SELECT pubkey FROM pubkeys WHERE fingerprint=?`, fp).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("gate: registry lookup %s: %w", fp, err)
	}
	if len(raw) != ed25519.PublicKeySize {
		return nil, false, fmt.Errorf("gate: registry pubkey for %s is %d bytes, want %d", fp, len(raw), ed25519.PublicKeySize)
	}
	return ed25519.PublicKey(raw), true, nil
}

// Close releases database resources held by the registry.
func (r *Registry) Close() error {
	return r.db.Close()
}
