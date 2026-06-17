package gate

import (
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
