package gate

import (
	"fmt"
	"strconv"
	"strings"
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

// TestLimiterSweepsAtMostOncePerInterval pins the sweep throttle. The cap
// bounds memory but not CPU: an unconditional sweep walks the whole map on
// every Allow under the global mutex, so at the cap that is 100k iterations per
// challenge request. Sweeping at most once per sweepInterval makes the common
// request O(1); evicting a tenth of a TTL late is free, since a stale bucket is
// a full bucket.
func TestLimiterSweepsAtMostOncePerInterval(t *testing.T) {
	fakeNow := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)

	l := NewLimiter(60)
	l.now = func() time.Time { return fakeNow }

	// First Allow sweeps (lastSweep is the zero value) and seeds one bucket.
	l.Allow("stale")
	if got := len(l.buckets); got != 1 {
		t.Fatalf("want 1 bucket after seeding, got %d", got)
	}

	// "stale" is now well past staleTTL, but we are still inside sweepInterval
	// of the last sweep: an Allow here must NOT walk the map. Advancing by
	// staleTTL would also cross sweepInterval, so hold the clock still and
	// backdate the bucket instead — that isolates the throttle from the TTL.
	l.buckets["stale"].lastSeen = fakeNow.Add(-staleTTL - time.Minute)
	l.Allow("fresh")
	if got := len(l.buckets); got != 2 {
		t.Fatalf("sweep ran inside sweepInterval: want 2 buckets, got %d", got)
	}
	if !l.buckets["stale"].lastSeen.Before(fakeNow) {
		t.Fatal("test setup: stale bucket was touched")
	}

	// Cross sweepInterval — the next Allow sweeps, evicting only the stale one.
	fakeNow = fakeNow.Add(sweepInterval)
	l.Allow("fresh")
	if _, ok := l.buckets["stale"]; ok {
		t.Fatal("stale bucket survived a sweep past sweepInterval")
	}
	if got := len(l.buckets); got != 1 {
		t.Fatalf("want only the fresh bucket after sweep, got %d", got)
	}
}

// TestLimiterLogsShedTransitions pins that entering and leaving shed mode is
// visible. Shedding returns false, byte-identical to an ordinary rate denial,
// so without a log an operator cannot tell a flood that overran the cap from
// ordinary per-key limiting. Each transition must log ONCE, not per request.
func TestLimiterLogsShedTransitions(t *testing.T) {
	fakeNow := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)

	var lines []string
	l := NewLimiter(60)
	l.now = func() time.Time { return fakeNow }
	l.logf = func(format string, args ...any) {
		lines = append(lines, fmt.Sprintf(format, args...))
	}
	l.maxBuckets = 3

	for i := 0; i < 3; i++ {
		l.Allow(strconv.Itoa(i))
	}
	if len(lines) != 0 {
		t.Fatalf("no transition yet, but logged: %v", lines)
	}

	// Three distinct new keys are shed; the transition logs exactly once.
	for _, k := range []string{"flood-a", "flood-b", "flood-c"} {
		if l.Allow(k) {
			t.Fatalf("new key %q beyond the cap must be shed", k)
		}
	}
	if len(lines) != 1 {
		t.Fatalf("entering shed mode must log once, got %d: %v", len(lines), lines)
	}
	if !strings.Contains(lines[0], "shedding new keys") ||
		!strings.Contains(lines[0], "buckets=3") || !strings.Contains(lines[0], "max=3") {
		t.Fatalf("shed log must name the cardinality and the cap, got %q", lines[0])
	}

	// Idle out the tracked keys, then cross sweepInterval so the sweep runs:
	// cardinality drops below the cap and the recovery transition logs once.
	fakeNow = fakeNow.Add(staleTTL + time.Minute)
	if !l.Allow("recovered") {
		t.Fatal("a new key must be admitted once the map drops below the cap")
	}
	if len(lines) != 2 {
		t.Fatalf("leaving shed mode must log once, got %d: %v", len(lines), lines)
	}
	if !strings.Contains(lines[1], "no longer shedding") {
		t.Fatalf("recovery log = %q", lines[1])
	}
	l.Allow("recovered")
	if len(lines) != 2 {
		t.Fatalf("recovery must not re-log per request, got %v", lines)
	}
}
