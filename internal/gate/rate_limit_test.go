package gate

import (
	"strconv"
	"testing"
	"time"
)

func TestLimiterPerKey(t *testing.T) {
	l := NewLimiter(60)
	for i := 0; i < 60; i++ {
		if !l.Allow("k") {
			t.Fatalf("req %d should pass", i)
		}
	}
	if l.Allow("k") {
		t.Fatal("61st must be limited")
	}
	if !l.Allow("other") {
		t.Fatal("other key must be independent")
	}
}

func TestLimiterRefillAfterWindow(t *testing.T) {
	var fakeNow time.Time
	fakeNow = time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)

	l := NewLimiter(60)
	l.now = func() time.Time { return fakeNow }

	// Exhaust the bucket.
	for i := 0; i < 60; i++ {
		if !l.Allow("k") {
			t.Fatalf("req %d should pass", i)
		}
	}
	if l.Allow("k") {
		t.Fatal("61st must be limited")
	}

	// Advance clock by one full minute — bucket refills.
	fakeNow = fakeNow.Add(time.Minute)
	if !l.Allow("k") {
		t.Fatal("after window advance, first request must pass")
	}
}

func TestLimiterSweepsStaleBuckets(t *testing.T) {
	fakeNow := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)

	l := NewLimiter(60)
	l.now = func() time.Time { return fakeNow }

	// Allocate many buckets across distinct keys.
	const n = 1000
	for i := 0; i < n; i++ {
		l.Allow(strconv.Itoa(i))
	}
	if got := len(l.buckets); got != n {
		t.Fatalf("before sweep: want %d buckets, got %d", n, got)
	}

	// Advance the clock past staleTTL; the next Allow opportunistically sweeps
	// every idle bucket, leaving only the one it just touched.
	fakeNow = fakeNow.Add(staleTTL + time.Minute)
	l.Allow("fresh")
	if got := len(l.buckets); got != 1 {
		t.Fatalf("after sweep: want only the fresh bucket, got %d", got)
	}
}

func TestLimiterCapsBucketCardinality(t *testing.T) {
	fakeNow := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)

	l := NewLimiter(60)
	l.now = func() time.Time { return fakeNow }
	l.maxBuckets = 3

	// Fill the map to the cap with distinct (never-before-seen) keys.
	for i := 0; i < 3; i++ {
		if !l.Allow(strconv.Itoa(i)) {
			t.Fatalf("key %d under cap should be allowed", i)
		}
	}
	if got := len(l.buckets); got != 3 {
		t.Fatalf("want 3 buckets at cap, got %d", got)
	}

	// A brand-new key beyond the cap is shed (denied) rather than allocating a
	// new bucket, so a distributed flood of distinct keys cannot grow the map.
	if l.Allow("overflow") {
		t.Fatal("new key beyond cap must be denied")
	}
	if got := len(l.buckets); got != 3 {
		t.Fatalf("map must not grow beyond cap: got %d", got)
	}

	// An already-tracked key is still served at the cap — the cap only blocks
	// new allocations, never existing buckets.
	if !l.Allow("0") {
		t.Fatal("existing key at cap must still be served")
	}
}

func TestLimiterConcurrent(t *testing.T) {
	l := NewLimiter(60)
	done := make(chan struct{})
	for i := 0; i < 10; i++ {
		go func(id int) {
			// Each goroutine uses a unique key so they don't interfere.
			key := string(rune('a' + id))
			for j := 0; j < 60; j++ {
				if !l.Allow(key) {
					t.Errorf("goroutine %d req %d should pass", id, j)
				}
			}
			done <- struct{}{}
		}(i)
	}
	for i := 0; i < 10; i++ {
		<-done
	}
}
