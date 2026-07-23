package gate

import (
	"sync"
	"time"
)

// staleTTL bounds bucket retention. A bucket refills fully in one minute, so a
// bucket untouched for staleTTL is guaranteed full and carries no state a
// freshly-created bucket wouldn't — evicting it is semantically free. Sweeping
// on Allow caps map cardinality even under a large registry with high churn.
const staleTTL = 5 * time.Minute

// defaultMaxBuckets caps live bucket cardinality. The challenge limiter is
// keyed by unauthenticated client IP (unlike the download limiter, which is
// gated to registry-validated fingerprints), so a distributed flood of
// distinct IPs would otherwise grow the map to the number of distinct IPs seen
// within staleTTL — unbounded memory, and an O(n) sweep per Allow that turns
// O(n²) under the flood. Once the map reaches the cap, keys with no existing
// bucket are shed (denied) instead of allocating, bounding both. The stale
// sweep runs first, so the cap only bites when genuinely many distinct keys
// are active at once. ~100k buckets is a generous ceiling for legitimate IP
// diversity while keeping worst-case memory in the tens of MB.
const defaultMaxBuckets = 100_000

// bucket holds the token state for a single rate-limit key.
type bucket struct {
	tokens   float64
	lastSeen time.Time
}

// Limiter is a thread-safe per-key token-bucket rate limiter.
// Cap = perMinute tokens; refill rate = perMinute tokens/min.
// Create with NewLimiter; call Allow(key) to consume one token.
type Limiter struct {
	mu         sync.Mutex
	perMin     float64
	buckets    map[string]*bucket
	maxBuckets int
	now        func() time.Time
}

// NewLimiter returns a Limiter that allows perMinute requests per key per minute.
func NewLimiter(perMinute int) *Limiter {
	return &Limiter{
		perMin:     float64(perMinute),
		buckets:    make(map[string]*bucket),
		maxBuckets: defaultMaxBuckets,
		now:        time.Now,
	}
}

// Allow reports whether the request for key is within the rate limit.
// It consumes one token from key's bucket; if no tokens remain it returns false.
func (l *Limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := l.now()

	// Opportunistic sweep of stale (idle, fully-refilled) buckets, mirroring
	// NonceStore.Issue. Belt-and-suspenders on top of the caller only keying
	// this limiter by registry-validated fingerprints.
	for k, sb := range l.buckets {
		if now.Sub(sb.lastSeen) > staleTTL {
			delete(l.buckets, k)
		}
	}

	b, ok := l.buckets[key]
	if !ok {
		// Shed new keys once the map is full so a distributed flood of distinct
		// keys cannot grow it without limit. Existing buckets are unaffected.
		if len(l.buckets) >= l.maxBuckets {
			return false
		}
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
