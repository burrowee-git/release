package gate

import (
	"sync"
	"time"
)

// bucket holds the token state for a single rate-limit key.
type bucket struct {
	tokens   float64
	lastSeen time.Time
}

// Limiter is a thread-safe per-key token-bucket rate limiter.
// Cap = perMinute tokens; refill rate = perMinute tokens/min.
// Create with NewLimiter; call Allow(key) to consume one token.
type Limiter struct {
	mu      sync.Mutex
	perMin  float64
	buckets map[string]*bucket
	now     func() time.Time
}

// NewLimiter returns a Limiter that allows perMinute requests per key per minute.
func NewLimiter(perMinute int) *Limiter {
	return &Limiter{
		perMin:  float64(perMinute),
		buckets: make(map[string]*bucket),
		now:     time.Now,
	}
}

// Allow reports whether the request for key is within the rate limit.
// It consumes one token from key's bucket; if no tokens remain it returns false.
func (l *Limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := l.now()
	b, ok := l.buckets[key]
	if !ok {
		b = &bucket{tokens: l.perMin, lastSeen: now}
		l.buckets[key] = b
	}

	// Refill tokens proportional to elapsed time.
	elapsed := now.Sub(b.lastSeen).Seconds()
	b.tokens += elapsed * (l.perMin / 60.0)
	if b.tokens > l.perMin {
		b.tokens = l.perMin
	}
	b.lastSeen = now

	if b.tokens < 1.0 {
		return false
	}
	b.tokens--
	return true
}
