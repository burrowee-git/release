package gate

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestNonceSingleUse(t *testing.T) {
	s := NewNonceStore(time.Minute)
	n := s.Issue()
	if !s.Consume(n) {
		t.Fatal("first consume must succeed")
	}
	if s.Consume(n) {
		t.Fatal("second consume must fail (single-use)")
	}
	if s.Consume("nope") {
		t.Fatal("unknown nonce must fail")
	}
}

func TestNonceExpiry(t *testing.T) {
	s := NewNonceStore(10 * time.Millisecond)
	n := s.Issue()
	time.Sleep(25 * time.Millisecond)
	if s.Consume(n) {
		t.Fatal("expired nonce must fail")
	}
}

func TestNonceConcurrentConsume(t *testing.T) {
	s := NewNonceStore(time.Minute)
	n := s.Issue()

	const goroutines = 50
	var wins atomic.Int32
	var wg sync.WaitGroup
	ready := make(chan struct{})

	wg.Add(goroutines)
	for range goroutines {
		go func() {
			defer wg.Done()
			<-ready
			if s.Consume(n) {
				wins.Add(1)
			}
		}()
	}
	close(ready)
	wg.Wait()

	if got := wins.Load(); got != 1 {
		t.Fatalf("concurrent consume: want exactly 1 winner, got %d", got)
	}
}
