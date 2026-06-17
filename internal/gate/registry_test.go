package gate

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

func TestRegistryLookup(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	fp := Fingerprint(pub)

	dbPath := filepath.Join(t.TempDir(), "reg.db")

	h, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	_, err = h.Exec(`CREATE TABLE pubkeys(fingerprint TEXT PRIMARY KEY, pubkey BLOB NOT NULL, label TEXT, added_at INTEGER)`)
	if err != nil {
		t.Fatalf("create table: %v", err)
	}
	_, err = h.Exec(`INSERT INTO pubkeys(fingerprint,pubkey,label,added_at) VALUES(?,?,?,0)`, fp, []byte(pub), "t")
	if err != nil {
		t.Fatalf("insert: %v", err)
	}
	if err := h.Close(); err != nil {
		t.Fatalf("close setup db: %v", err)
	}

	r, err := OpenRegistry(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()

	got, ok, err := r.Lookup(fp)
	if err != nil || !ok {
		t.Fatalf("lookup miss: ok=%v err=%v", ok, err)
	}
	if !bytes.Equal(got, pub) {
		t.Fatal("pubkey mismatch")
	}

	_, ok, err = r.Lookup("deadbeefdeadbeef")
	if err != nil {
		t.Fatalf("unknown fp lookup error: %v", err)
	}
	if ok {
		t.Fatal("unknown fp should miss")
	}
}
