package worker

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"services/comms-connector/internal/keys"
	"services/comms-connector/internal/lease"
	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/rails"
)

// stubRails sequences like CommsEvents and refuses any event containing
// "POISON" as invalid.
type stubRails struct {
	mu        sync.Mutex
	committed int64
	applied   []string
}

func (s *stubRails) Post(_ context.Context, _ string, _ []byte, body []byte) (rails.Reply, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var ev struct {
		Seq  int64  `json:"seq"`
		Type string `json:"type"`
	}
	json.Unmarshal(body, &ev)
	c := s.committed
	switch {
	case ev.Seq <= c:
		return rails.Reply{Status: 200, CommittedSeq: &c}, nil
	case ev.Seq > c+1:
		return rails.Reply{Status: 409, Error: "sequence_gap", CommittedSeq: &c}, nil
	case strings.Contains(string(body), "POISON"):
		return rails.Reply{Status: 422, Error: "invalid_record"}, nil
	}
	s.committed = ev.Seq
	s.applied = append(s.applied, string(body))
	n := s.committed
	return rails.Reply{Status: 200, CommittedSeq: &n}, nil
}

func TestPoisonEventIsDroppedAndDeliveryContinues(t *testing.T) {
	r := &stubRails{}
	w, err := Open(context.Background(), Config{
		DataDir: t.TempDir(), Ref: "svc_5", StoreKey: bytes.Repeat([]byte{5}, 32), Rails: r,
		Log: slog.New(slog.NewTextHandler(io.Discard, nil)), MinBackoff: time.Millisecond, MaxBackoff: 5 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	w.SetSecret(context.Background(), "s", 1)
	ctx := context.Background()
	s := (*sink)(w)
	body := func(text string) *string { return &text }
	s.Messages(ctx, []provider.Message{{ProviderMessageID: "a", Chat: "c", SentAt: time.Now(), Body: body("first")}})
	s.Messages(ctx, []provider.Message{{ProviderMessageID: "b", Chat: "c", SentAt: time.Now(), Body: body("POISON")}})
	s.Messages(ctx, []provider.Message{{ProviderMessageID: "c", Chat: "c", SentAt: time.Now(), Body: body("after")}})

	sctx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() { w.send(sctx); close(done) }()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		r.mu.Lock()
		n := len(r.applied)
		r.mu.Unlock()
		if n == 2 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	<-done
	if len(r.applied) != 2 || !strings.Contains(r.applied[0], "first") || !strings.Contains(r.applied[1], "after") {
		t.Fatalf("applied %v", r.applied)
	}
	if depth, _ := w.st.OutboxDepth(ctx); depth != 0 {
		t.Fatalf("outbox depth %d", depth)
	}
}

// scriptedRails sequences like CommsEvents, but answers each attempt to
// deliver the event under test from a script: "422", "down" (no reply) or
// "ok".
type scriptedRails struct {
	stubRails
	script []string
	posts  int
}

var errDown = errors.New("down")

func (s *scriptedRails) Post(ctx context.Context, ref string, secret []byte, body []byte) (rails.Reply, error) {
	var ev struct {
		Seq int64 `json:"seq"`
	}
	json.Unmarshal(body, &ev)
	s.mu.Lock()
	probe := ev.Seq != s.committed+1
	step := ""
	if !probe && len(s.script) > 0 {
		step, s.script = s.script[0], s.script[1:]
		s.posts++
	}
	s.mu.Unlock()
	switch step {
	case "422":
		return rails.Reply{Status: 422, Error: "invalid_record"}, nil
	case "down":
		return rails.Reply{}, errDown
	}
	return s.stubRails.Post(ctx, ref, secret, body)
}

// "Five times running" means consecutive: a transport failure between
// refusals starts the count again, so four refusals, an outage and four
// more do not drop the event. Five in a row do, and only that event (one
// whole batch) goes; the next is delivered.
func TestOnlyConsecutiveRefusalsDropAnEvent(t *testing.T) {
	run := func(script []string) (*scriptedRails, *Worker) {
		r := &scriptedRails{script: script}
		w, err := Open(context.Background(), Config{
			DataDir: t.TempDir(), Ref: "svc_5", StoreKey: bytes.Repeat([]byte{5}, 32), Rails: r,
			Log: slog.New(slog.NewTextHandler(io.Discard, nil)), MinBackoff: time.Millisecond, MaxBackoff: 2 * time.Millisecond,
		})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(w.Close)
		w.SetSecret(context.Background(), "s", 1)
		ctx := context.Background()
		text := func(s string) *string { return &s }
		s := (*sink)(w)
		s.Messages(ctx, []provider.Message{{ProviderMessageID: "a", Chat: "c", SentAt: time.Now(), Body: text("under test")}})
		s.Messages(ctx, []provider.Message{{ProviderMessageID: "b", Chat: "c", SentAt: time.Now(), Body: text("next")}})
		sctx, cancel := context.WithCancel(ctx)
		done := make(chan struct{})
		go func() { w.send(sctx); close(done) }()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if depth, _ := w.st.OutboxDepth(ctx); depth == 0 {
				break
			}
			time.Sleep(2 * time.Millisecond)
		}
		cancel()
		<-done
		return r, w
	}

	r, _ := run([]string{"422", "422", "422", "422", "down", "422", "422", "422", "422", "ok"})
	if len(r.applied) != 2 || !strings.Contains(r.applied[0], "under test") {
		t.Fatalf("interrupted refusals dropped the event: applied %v", r.applied)
	}

	r, _ = run([]string{"422", "422", "422", "422", "422"})
	if len(r.applied) != 1 || !strings.Contains(r.applied[0], "next") || r.posts != 5 {
		t.Fatalf("five refusals in a row: applied %v after %d posts", r.applied, r.posts)
	}
}

func TestBatchesStayInsideRailsLimits(t *testing.T) {
	big := strings.Repeat("é", 40<<10) // 80 KiB of UTF-8, past maxText
	var msgs []provider.Message
	for i := 0; i < 450; i++ {
		b := big
		msgs = append(msgs, provider.Message{ProviderMessageID: "m", Chat: "c", Body: &b})
	}
	bodies, err := encodeMessages(msgs)
	if err != nil {
		t.Fatal(err)
	}
	total := 0
	for _, b := range bodies {
		var ev messageEvent
		if err := json.Unmarshal(b, &ev); err != nil {
			t.Fatal(err)
		}
		if len(ev.Messages) > maxBatch || len(b) > 1<<20 {
			t.Fatalf("event of %d messages, %d bytes", len(ev.Messages), len(b))
		}
		for _, m := range ev.Messages {
			if len(*m.Body) > maxText || !strings.HasPrefix(big, *m.Body) {
				t.Fatal("body not clamped at a rune boundary")
			}
		}
		total += len(ev.Messages)
	}
	if total != 450 {
		t.Fatalf("lost messages: %d", total)
	}
}

func TestStamp(t *testing.T) {
	if got := string(stamp([]byte(`{"type":"x"}`), 7, 3)); got != `{"seq":7,"attempt":3,"type":"x"}` {
		t.Fatal(got)
	}
	if got := string(stamp([]byte(`{"type":"pairing.qr"}`), 0, 3)); got != `{"attempt":3,"type":"pairing.qr"}` {
		t.Fatal(got)
	}
}

// Unpair deletes the store and the connection directory while it still
// holds the lease: at the moment the files are gone, nobody else can take
// the connection, and afterwards the lease is the same file, not a new
// inode in a recreated directory.
func TestUnpairDeletesBeforeReleasingTheLease(t *testing.T) {
	data := t.TempDir()
	cfg := Config{
		DataDir: data, Ref: "svc_6", StoreKey: bytes.Repeat([]byte{6}, 32), Rails: &stubRails{},
		Factory: provider.DefaultSynthetic().Factory(), Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	w, err := Open(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	leasePath, _ := keys.LeasePath(data, "svc_6")
	before, err := os.Stat(leasePath)
	if err != nil {
		t.Fatal(err)
	}
	var during error
	var dirGone bool
	testHookBeforeLeaseRelease = func() {
		_, statErr := os.Stat(filepath.Join(data, "svc_6"))
		dirGone = errors.Is(statErr, os.ErrNotExist)
		_, during = Open(context.Background(), cfg)
	}
	defer func() { testHookBeforeLeaseRelease = nil }()
	if err := w.Unpair(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !dirGone || !errors.Is(during, lease.ErrHeld) {
		t.Fatalf("while deleting: directory gone %v, second open %v", dirGone, during)
	}
	after, err := os.Stat(leasePath)
	if err != nil || !os.SameFile(before, after) {
		t.Fatalf("lease file replaced or removed: %v", err)
	}
	w2, err := Open(context.Background(), cfg)
	if err != nil {
		t.Fatalf("open after unpair: %v", err)
	}
	w2.Close()
}
