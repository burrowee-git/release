package gate

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"sync"
	"time"
)

// NonceStore issues single-use, time-limited nonces. Issue generates a random
// 32-byte nonce (base64 std-encoded); Consume returns true exactly once for an
// unexpired, previously-issued nonce. All methods are thread-safe.
type NonceStore struct {
	mu  sync.Mutex
	ttl time.Duration
	m   map[string]time.Time
}

// NewNonceStore returns a NonceStore that expires nonces after ttl.
func NewNonceStore(ttl time.Duration) *NonceStore {
	return &NonceStore{ttl: ttl, m: make(map[string]time.Time)}
}

// Issue generates a new random nonce and records its expiry. It also sweeps
// expired entries from the store to bound memory growth.
func (s *NonceStore) Issue() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		// crypto/rand.Read on supported platforms never fails; if it does,
		// producing a weak nonce would be silently catastrophic — panic instead.
		panic(fmt.Sprintf("gate: nonce: crypto/rand.Read failed: %v", err))
	}
	n := base64.StdEncoding.EncodeToString(b)

	s.mu.Lock()
	defer s.mu.Unlock()

	// Opportunistic sweep of expired entries.
	now := time.Now()
	for k, exp := range s.m {
		if now.After(exp) {
			delete(s.m, k)
		}
	}

	s.m[n] = now.Add(s.ttl)
	return n
}

// Consume returns true if and only if the nonce was issued by this store,
// has not yet been consumed, and has not expired. On true, the nonce is
// deleted so no subsequent call can consume it again.
func (s *NonceStore) Consume(n string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	exp, ok := s.m[n]
	if !ok {
		return false
	}
	delete(s.m, n)
	return time.Now().Before(exp)
}
