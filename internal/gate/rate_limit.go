package gate

import (
	"log"
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

// sweepInterval throttles the stale sweep. The cap bounds memory but not CPU:
// an unconditional sweep walks the WHOLE map on every Allow under the single
// global mutex, so at the cap that is 100k iterations per challenge request,
// serialised — the distributed flood the cap was added to survive would still
// degrade the gate. Evicting late costs nothing (a stale bucket is a full
// bucket, semantically identical to a fresh one), so sweeping at most once per
// staleTTL/10 keeps retention within a tenth of the TTL while making the
// per-request cost O(1) in the common case.
const sweepInterval = staleTTL / 10

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
	// lastSweep is when the stale sweep last ran; the zero value makes the
	// first Allow sweep.
	lastSweep time.Time
	// shedding records whether the cap is currently rejecting new keys, so the
	// two transitions are logged once each instead of per request. Shedding is
	// otherwise invisible: it returns false, indistinguishable from an ordinary
	// rate denial.
	shedding bool
	// logf reports the shed transitions. Tests swap it to capture them.
	logf func(format string, args ...any)
}

// NewLimiter returns a Limiter that allows perMinute requests per key per minute.
func NewLimiter(perMinute int) *Limiter {
	return &Limiter{
		perMin:     float64(perMinute),
		buckets:    make(map[string]*bucket),
		maxBuckets: defaultMaxBuckets,
		now:        time.Now,
		logf:       log.Printf,
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
	// this limiter by registry-validated fingerprints. Throttled to once per
	// sweepInterval so the O(n) walk cannot run per request under a flood.
	if now.Sub(l.lastSweep) >= sweepInterval {
		for k, sb := range l.buckets {
			if now.Sub(sb.lastSeen) > staleTTL {
				delete(l.buckets, k)
			}
		}
		l.lastSweep = now
	}

	b, ok := l.buckets[key]
	if !ok {
		// Shed new keys once the map is full so a distributed flood of distinct
		// keys cannot grow it without limit. Existing buckets are unaffected.
		if len(l.buckets) >= l.maxBuckets {
			l.setShedding(true)
			return false
		}
		b = &bucket{tokens: l.perMin, lastSeen: now}
		l.buckets[key] = b
	}
	// Leaving shed mode is driven by cardinality, not by this key: an existing
	// key served while the map still sits at the cap is not recovery.
	if len(l.buckets) < l.maxBuckets {
		l.setShedding(false)
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

// setShedding records the shed state and logs each transition once. Caller must
// hold l.mu.
func (l *Limiter) setShedding(on bool) {
	if l.shedding == on {
		return
	}
	l.shedding = on
	if l.logf == nil {
		return
	}
	if on {
		l.logf("gate: rate limiter shedding new keys — bucket cardinality reached the cap (buckets=%d max=%d)",
			len(l.buckets), l.maxBuckets)
		return
	}
	l.logf("gate: rate limiter no longer shedding new keys (buckets=%d max=%d)",
		len(l.buckets), l.maxBuckets)
}
