package worker

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/rails"
	"services/comms-connector/internal/store"
)

// Mira's review of #357: within one attempt the owner can ask for a phone
// code more than once (a replacement number, a retry, another tab). Each
// pair_phone names its request; every result reaching Rails names the
// request it answers, and a result for a request that has since been
// superseded is not posted at all, in whichever order the provider ran them.

const (
	requestA = "aaaaaaaaaaaaaaaa"
	requestB = "bbbbbbbbbbbbbbbb"
)

// gatedSession pairs forever; each phone request blocks until the test
// releases it (keyed by number), then reports what it was given. It ignores
// cancellation on purpose: a provider may still answer a request after it
// was superseded, and the worker must not pass that answer on.
type gatedSession struct {
	mu        sync.Mutex
	gates     map[string]chan gatedResult
	started   map[string]bool // RequestPhoneCode was called for this number
	cancelled map[string]bool // its context was cancelled by the time it answered
	done      sync.WaitGroup
}

func (g *gatedSession) wasStarted(phone string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.started[phone]
}

func (g *gatedSession) wasCancelled(phone string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.cancelled[phone]
}

type gatedResult struct{ code, failure string }

func (g *gatedSession) gate(phone string) chan gatedResult {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.gates[phone] == nil {
		g.gates[phone] = make(chan gatedResult, 1)
	}
	return g.gates[phone]
}

func (g *gatedSession) Run(ctx context.Context, _ provider.Sink, _ bool) error {
	<-ctx.Done()
	return ctx.Err()
}

func (g *gatedSession) Logout(context.Context) error { return nil }

func (g *gatedSession) RequestPhoneCode(ctx context.Context, sink provider.Sink, phone string) error {
	g.done.Add(1)
	defer g.done.Done()
	g.mu.Lock()
	g.started[phone] = true
	g.mu.Unlock()
	res := <-g.gate(phone)
	g.mu.Lock()
	g.cancelled[phone] = ctx.Err() != nil
	g.mu.Unlock()
	if res.failure != "" {
		return sink.PhoneCodeFailed(context.Background(), res.failure)
	}
	now := time.Now()
	return sink.PhoneCode(context.Background(), res.code, now, now.Add(time.Minute))
}

// phoneRails records every phone event it is sent and accepts it.
type phoneRails struct {
	mu     sync.Mutex
	events []map[string]any
}

func (p *phoneRails) Post(_ context.Context, _ string, _ []byte, body []byte) (rails.Reply, error) {
	var ev map[string]any
	json.Unmarshal(body, &ev)
	if t, _ := ev["type"].(string); strings.HasPrefix(t, "pairing.phone_code") {
		p.mu.Lock()
		p.events = append(p.events, ev)
		p.mu.Unlock()
	}
	return rails.Reply{Status: 200}, nil
}

func (p *phoneRails) snapshot() []map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]map[string]any(nil), p.events...)
}

func startGated(t *testing.T) (*Worker, *gatedSession, *phoneRails) {
	t.Helper()
	g := &gatedSession{gates: map[string]chan gatedResult{}, started: map[string]bool{}, cancelled: map[string]bool{}}
	r := &phoneRails{}
	w, err := Open(context.Background(), Config{
		DataDir: t.TempDir(), Ref: "svc_7", StoreKey: bytes.Repeat([]byte{7}, 32), Rails: r,
		Factory: func(*store.Store) (provider.Session, error) { return g, nil },
		Log:     slog.New(slog.NewTextHandler(io.Discard, nil)), MinBackoff: time.Millisecond, MaxBackoff: 5 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := w.SetSecret(context.Background(), "s3cret", 1); err != nil {
		t.Fatal(err)
	}
	if err := w.Start(true); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(w.Close)
	return w, g, r
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// settle lets every released request finish posting (or not) before the
// test reads what Rails got.
func settle(w *Worker, g *gatedSession) {
	g.done.Wait()
	w.bg.Wait()
}

func TestPhoneResultNamesItsRequest(t *testing.T) {
	w, g, r := startGated(t)
	if err := w.PairPhone("447700900001", 1, requestA, 1); err != nil {
		t.Fatal(err)
	}
	g.gate("447700900001") <- gatedResult{code: "AAAA-AAAA"}
	waitFor(t, "the code at Rails", func() bool { return len(r.snapshot()) == 1 })
	ev := r.snapshot()[0]
	if ev["type"] != "pairing.phone_code" || ev["code"] != "AAAA-AAAA" || ev["request_id"] != requestA {
		t.Fatalf("event %v", ev)
	}
	g.gate("447700900002") // unused
	if err := w.PairPhone("447700900002", 1, requestB, 2); err != nil {
		t.Fatal(err)
	}
	g.gate("447700900002") <- gatedResult{failure: provider.PhoneCodeRateLimited}
	waitFor(t, "the failure at Rails", func() bool { return len(r.snapshot()) == 2 })
	if ev := r.snapshot()[1]; ev["type"] != "pairing.phone_code_failed" || ev["request_id"] != requestB {
		t.Fatalf("event %v", ev)
	}
}

// Delayed success: A's code comes back after B was accepted (and before
// B's): it is not posted; B's is, naming B.
func TestDelayedCodeOfASupersededRequestIsNotPosted(t *testing.T) {
	w, g, r := startGated(t)
	if err := w.PairPhone("447700900001", 1, requestA, 1); err != nil {
		t.Fatal(err)
	}
	if err := w.PairPhone("447700900002", 1, requestB, 2); err != nil {
		t.Fatal(err)
	}
	g.gate("447700900001") <- gatedResult{code: "AAAA-AAAA"}
	g.gate("447700900002") <- gatedResult{code: "BBBB-BBBB"}
	settle(w, g)
	got := r.snapshot()
	if len(got) != 1 || got[0]["code"] != "BBBB-BBBB" || got[0]["request_id"] != requestB {
		t.Fatalf("Rails got %v, want only B's code", got)
	}
}

// Delayed failure: A fails after B got its code; nothing about A is posted,
// so B's code stands.
func TestDelayedFailureOfASupersededRequestIsNotPosted(t *testing.T) {
	w, g, r := startGated(t)
	if err := w.PairPhone("447700900001", 1, requestA, 1); err != nil {
		t.Fatal(err)
	}
	if err := w.PairPhone("447700900002", 1, requestB, 2); err != nil {
		t.Fatal(err)
	}
	g.gate("447700900002") <- gatedResult{code: "BBBB-BBBB"}
	waitFor(t, "B's code at Rails", func() bool { return len(r.snapshot()) == 1 })
	g.gate("447700900001") <- gatedResult{failure: provider.PhoneCodeFailed}
	settle(w, g)
	got := r.snapshot()
	if len(got) != 1 || got[0]["code"] != "BBBB-BBBB" || got[0]["request_id"] != requestB {
		t.Fatalf("Rails got %v, want only B's code", got)
	}
}

// Reversed execution: B (accepted second) finishes first, then A, whose
// code is the newer one by issue time. Still only B's reaches Rails.
func TestReversedExecutionStillPostsOnlyTheLatestRequest(t *testing.T) {
	w, g, r := startGated(t)
	if err := w.PairPhone("447700900001", 1, requestA, 1); err != nil {
		t.Fatal(err)
	}
	if err := w.PairPhone("447700900002", 1, requestB, 2); err != nil {
		t.Fatal(err)
	}
	g.gate("447700900002") <- gatedResult{code: "BBBB-BBBB"}
	waitFor(t, "B's code at Rails", func() bool { return len(r.snapshot()) == 1 })
	time.Sleep(2 * time.Millisecond) // A's issued_at is strictly later
	g.gate("447700900001") <- gatedResult{code: "AAAA-AAAA"}
	settle(w, g)
	got := r.snapshot()
	if len(got) != 1 || got[0]["code"] != "BBBB-BBBB" || got[0]["request_id"] != requestB {
		t.Fatalf("Rails got %v, want only B's code", got)
	}
}

// A request id must be given: Rails refuses results that name none.
func TestPairPhoneNeedsARequest(t *testing.T) {
	w, _, _ := startGated(t)
	if err := w.PairPhone("447700900001", 1, "", 1); err == nil {
		t.Fatal("a pair_phone without a request id was accepted")
	}
}

// Mira's second review: Rails records A (seq 1) then B (seq 2), but B's
// command reaches the connector first. A's late command is refused before
// it can cancel anything; B runs uncancelled and its code reaches Rails.
func TestOlderCommandArrivingLateIsRefusedWithoutCancellingTheCurrentRequest(t *testing.T) {
	w, g, r := startGated(t)
	if err := w.PairPhone("447700900002", 1, requestB, 2); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "B started", func() bool { return g.wasStarted("447700900002") })
	if err := w.PairPhone("447700900001", 1, requestA, 1); !errors.Is(err, ErrStaleRequest) {
		t.Errorf("A after B: %v, want ErrStaleRequest", err)
	}
	g.gate("447700900002") <- gatedResult{code: "BBBB-BBBB"}
	g.gate("447700900001") <- gatedResult{code: "AAAA-AAAA"} // in case A was run
	settle(w, g)
	got := r.snapshot()
	if len(got) != 1 || got[0]["code"] != "BBBB-BBBB" || got[0]["request_id"] != requestB {
		t.Errorf("Rails got %v, want only B's code", got)
	}
	if g.wasCancelled("447700900002") {
		t.Error("A's late command cancelled B")
	}
	if g.wasStarted("447700900001") {
		t.Error("A's late command was run")
	}
}

// A repeat of the current sequence (same or another id) is no newer, and a
// sequence must be given.
func TestEqualOrMissingSequenceIsRefused(t *testing.T) {
	w, g, _ := startGated(t)
	if err := w.PairPhone("447700900002", 1, requestB, 2); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "B started", func() bool { return g.wasStarted("447700900002") })
	if err := w.PairPhone("447700900001", 1, requestA, 2); !errors.Is(err, ErrStaleRequest) {
		t.Errorf("equal sequence: %v", err)
	}
	if err := w.PairPhone("447700900001", 1, requestA, 0); err == nil {
		t.Error("sequence 0 accepted")
	}
	g.gate("447700900002") <- gatedResult{code: "BBBB-BBBB"}
	g.gate("447700900001") <- gatedResult{code: "AAAA-AAAA"}
	settle(w, g)
	if g.wasCancelled("447700900002") {
		t.Error("B was cancelled")
	}
}

// A newer sequence still supersedes: it cancels the current request.
func TestNewerSequenceCancelsTheCurrentRequest(t *testing.T) {
	w, g, r := startGated(t)
	if err := w.PairPhone("447700900001", 1, requestA, 1); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "A started", func() bool { return g.wasStarted("447700900001") })
	if err := w.PairPhone("447700900002", 1, requestB, 2); err != nil {
		t.Fatal(err)
	}
	g.gate("447700900001") <- gatedResult{code: "AAAA-AAAA"}
	g.gate("447700900002") <- gatedResult{code: "BBBB-BBBB"}
	settle(w, g)
	if !g.wasCancelled("447700900001") || g.wasCancelled("447700900002") {
		t.Fatalf("cancelled: A %v, B %v", g.wasCancelled("447700900001"), g.wasCancelled("447700900002"))
	}
	if got := r.snapshot(); len(got) != 1 || got[0]["request_id"] != requestB {
		t.Fatalf("Rails got %v", got)
	}
}

// Across a restart: Rails continues the sequence, and a command from the
// old attempt, whatever its sequence, cannot cancel the new attempt's
// request (refused by its attempt, before anything is cancelled).
func TestPreRestartCommandCannotCancelAPostRestartRequest(t *testing.T) {
	w, g, r := startGated(t)
	w.Stop()
	if err := w.SetSecret(context.Background(), "s3cret", 2); err != nil {
		t.Fatal(err)
	}
	if err := w.Start(true); err != nil {
		t.Fatal(err)
	}
	if err := w.PairPhone("447700900002", 2, requestB, 5); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "B started", func() bool { return g.wasStarted("447700900002") })
	if err := w.PairPhone("447700900001", 1, requestA, 9); !errors.Is(err, ErrStaleAttempt) {
		t.Errorf("pre-restart command: %v", err)
	}
	g.gate("447700900002") <- gatedResult{code: "BBBB-BBBB"}
	g.gate("447700900001") <- gatedResult{code: "AAAA-AAAA"}
	settle(w, g)
	if g.wasCancelled("447700900002") || g.wasStarted("447700900001") {
		t.Error("the pre-restart command cancelled or ran")
	}
	if got := r.snapshot(); len(got) != 1 || got[0]["request_id"] != requestB {
		t.Errorf("Rails got %v", got)
	}
}
