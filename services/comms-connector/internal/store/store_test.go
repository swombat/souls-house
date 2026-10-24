package store

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const canary = "CANARY-COMMS-store-7f3a"

func randKey(t *testing.T) []byte {
	t.Helper()
	k := make([]byte, 32)
	rand.Read(k)
	return k
}

func openT(t *testing.T, path string, key []byte) *Store {
	t.Helper()
	s, err := Open(context.Background(), path, key)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	return s
}

// fill queues n canary-bearing events, as the worker does with messages.
func fill(t *testing.T, s *Store, n int) {
	t.Helper()
	var bodies [][]byte
	for i := 0; i < n; i++ {
		bodies = append(bodies, []byte(fmt.Sprintf(`{"type":"message.upsert","messages":[{"body":"%s message %d %s"}]}`, canary, i, strings.Repeat("x", 200))))
	}
	if err := s.Enqueue(context.Background(), bodies...); err != nil {
		t.Fatal(err)
	}
}

// TestRestartSurvivesReopen is the ConnectHook trap test: a hook-keyed
// database works fresh and fails on reopen, so this test must reopen.
func TestRestartSurvivesReopen(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "store.db")
	key := randKey(t)
	s := openT(t, path, key)
	fill(t, s, 60)
	if err := s.SetMeta(ctx, map[string]string{"callback_secret": canary + "-secret"}); err != nil {
		t.Fatal(err)
	}
	s.Close()

	for i := 0; i < 2; i++ { // reopen twice: fresh pool each time
		s2 := openT(t, path, key)
		if n, err := s2.OutboxDepth(ctx); err != nil || n != 60 {
			t.Fatalf("reopen %d: outbox depth %d", i, n)
		}
		if v, ok, err := s2.Meta(ctx, "callback_secret"); err != nil || !ok || v != canary+"-secret" {
			t.Fatalf("reopen %d: meta lost", i)
		}
		s2.Close()
	}
}

func TestOutboxIsOrderedAndDeliveryDrops(t *testing.T) {
	ctx := context.Background()
	s := openT(t, filepath.Join(t.TempDir(), "store.db"), randKey(t))
	defer s.Close()
	if err := s.Enqueue(ctx, []byte("a"), []byte("b"), []byte("c")); err != nil {
		t.Fatal(err)
	}
	p, _ := s.Pending(ctx, 10)
	if len(p) != 3 || string(p[0].Body) != "a" || string(p[2].Body) != "c" || !(p[0].ID < p[1].ID && p[1].ID < p[2].ID) {
		t.Fatalf("pending %+v", p)
	}
	if err := s.Delivered(ctx, p[1].ID); err != nil {
		t.Fatal(err)
	}
	p2, _ := s.Pending(ctx, 10)
	if len(p2) != 1 || string(p2[0].Body) != "c" {
		t.Fatalf("after delivery %+v", p2)
	}
	// Ids are never reused after a delete (AUTOINCREMENT), so a wire sequence
	// derived from them never goes backwards.
	s.Delivered(ctx, p2[0].ID)
	s.Enqueue(ctx, []byte("d"))
	p3, _ := s.Pending(ctx, 10)
	if len(p3) != 1 || p3[0].ID <= p[2].ID {
		t.Fatalf("id reused: %+v", p3)
	}
	if err := s.Enqueue(ctx, nil); !errors.Is(err, ErrBadInput) {
		t.Fatal("empty event queued")
	}
}

func TestRemoveDeletesEveryFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "store.db")
	s := openT(t, path, randKey(t))
	fill(t, s, 5)
	s.Close()
	if err := Remove(path); err != nil {
		t.Fatal(err)
	}
	for _, suffix := range []string{"", "-wal", "-shm"} {
		if _, err := os.Stat(path + suffix); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("%s survived", suffix)
		}
	}
	if err := Remove(path); err != nil {
		t.Fatal("second remove failed")
	}
}

func TestWrongKeyFails(t *testing.T) {
	path := filepath.Join(t.TempDir(), "store.db")
	key := randKey(t)
	s := openT(t, path, key)
	fill(t, s, 3)
	s.Close()
	other := randKey(t)
	_, err := Open(context.Background(), path, other)
	if !errors.Is(err, ErrOpen) || err.Error() != "open comms store failed" {
		t.Fatalf("wrong key: got %v", err)
	}
	if _, err := Open(context.Background(), path, key[:31]); !errors.Is(err, ErrOpen) {
		t.Fatal("short key accepted")
	}
}

func TestPlaintextFileRefused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "plain.db")
	os.WriteFile(path, append([]byte("SQLite format 3\x00"), make([]byte, 4080)...), 0o600)
	if _, err := Open(context.Background(), path, randKey(t)); !errors.Is(err, ErrOpen) {
		t.Fatal("plaintext file opened")
	}
}

func scanFiles(t *testing.T, path string, key []byte, wantWAL bool) {
	t.Helper()
	needles := map[string][]byte{
		"canary":       []byte("CANARY-COMMS"),
		"raw key":      key,
		"hex key":      []byte(hex.EncodeToString(key)),
		"sqlite magic": []byte("SQLite format 3\x00"),
	}
	for _, suffix := range []string{"", "-wal", "-shm"} {
		b, err := os.ReadFile(path + suffix)
		if err != nil {
			if suffix != "" && !wantWAL && errors.Is(err, os.ErrNotExist) {
				continue
			}
			t.Fatalf("read %s: %v", suffix, err)
		}
		if suffix == "" && (len(b) < 16 || bytes.Equal(b[:16], []byte("SQLite format 3\x00"))) {
			t.Fatalf("db file header is plaintext SQLite")
		}
		for name, n := range needles {
			if bytes.Contains(b, n) {
				t.Errorf("file %q contains %s", "db"+suffix, name)
			}
		}
	}
}

func TestNoPlaintextOnDisk(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "store.db")
	key := randKey(t)
	s := openT(t, path, key)
	fill(t, s, 2000)
	// A sort large enough to want temp space, while the WAL is live.
	rows, err := s.db.Query("SELECT body FROM outbox ORDER BY body || queued_at DESC")
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
	}
	rows.Close()
	if fi, err := os.Stat(path + "-wal"); err != nil || fi.Size() == 0 {
		t.Fatalf("expected a live, non-empty WAL")
	}
	scanFiles(t, path, key, true) // live: db, -wal, -shm
	s.Close()
	scanFiles(t, path, key, false) // after close/checkpoint
	// Same check after a reopen-and-write cycle.
	s = openT(t, path, key)
	s.Enqueue(ctx, []byte(canary+"-late"))
	scanFiles(t, path, key, true)
	s.Close()
}

func TestTempStoreOnEveryPooledConnection(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "store.db")
	key := randKey(t)
	for round := 0; round < 2; round++ { // fresh and reopened
		s := openT(t, path, key)
		var conns []*sql.Conn
		for i := 0; i < 4; i++ { // MaxOpenConns: four distinct connections
			c, err := s.Conn(ctx)
			if err != nil {
				t.Fatal(err)
			}
			conns = append(conns, c)
			p, err := ConnPragmas(ctx, c)
			if err != nil || p != Want {
				t.Fatalf("round %d conn %d: pragmas %+v, want %+v", round, i, p, Want)
			}
			if p.TempStore != 2 {
				t.Fatalf("temp_store = %d, want 2", p.TempStore)
			}
		}
		var opts []string
		r, _ := conns[0].QueryContext(ctx, "PRAGMA compile_options")
		for r.Next() {
			var o string
			r.Scan(&o)
			opts = append(opts, o)
		}
		r.Close()
		if !strings.Contains(strings.Join(opts, " "), "TEMP_STORE=3") {
			t.Fatal("not compiled with SQLITE_TEMP_STORE=3")
		}
		for _, c := range conns {
			c.Close()
		}
		s.Close()
	}
}

func TestDSNNeverFormatted(t *testing.T) {
	path := filepath.Join(t.TempDir(), "store.db")
	key := randKey(t)
	s := openT(t, path, key)
	defer s.Close()
	dsn, _ := buildDSN(path, key)
	kc := newKeyedConnector(dsn, cipherDriver())
	var out strings.Builder
	for _, v := range []any{s, s.db, kc, &kc} {
		for _, f := range []string{"%v", "%+v", "%#v", "%s", "%q", "%x", "%d", "%T"} {
			fmt.Fprintf(&out, f+"\n", v)
		}
	}
	got := out.String()
	for _, n := range []string{"_key", "x'", hex.EncodeToString(key), "_cipher"} {
		if strings.Contains(got, n) {
			t.Fatalf("formatted store/connector contains %q", n)
		}
	}
}

func TestOpenErrorsAreFixed(t *testing.T) {
	for _, p := range []string{"", "a?b", "file:x.db", filepath.Join(t.TempDir(), "nodir", "x.db")} {
		_, err := Open(context.Background(), p, randKey(t))
		if err == nil || err.Error() != ErrOpen.Error() {
			t.Errorf("path %q: got %v", p, err)
		}
	}
}

// ResetSession starts a pairing over in one transaction: the session's own
// tables (including foreign keys between them) and every metadata value go,
// status events are dropped, and chats and messages move, in order, to the
// carryover, which EnqueueReleasingCarryover sends after a new status. The
// result survives a reopen.
func TestResetSessionCarriesOverChatsAndMessages(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "store.db")
	key := randKey(t)
	s := openT(t, path, key)
	for _, stmt := range []string{
		`CREATE TABLE whatsmeow_device (jid TEXT PRIMARY KEY)`,
		`CREATE TABLE whatsmeow_sessions (our_jid TEXT REFERENCES whatsmeow_device(jid) ON DELETE CASCADE, k TEXT)`,
		`INSERT INTO whatsmeow_device VALUES ('old@s.whatsapp.net')`,
		`INSERT INTO whatsmeow_sessions VALUES ('old@s.whatsapp.net', 'x')`,
	} {
		if _, err := s.DB().ExecContext(ctx, stmt); err != nil {
			t.Fatal(err)
		}
	}
	s.SetMeta(ctx, map[string]string{"callback_secret": "old", "seq_offset": "9"})
	s.Enqueue(ctx, []byte(`{"type":"status.changed","status":"connected"}`), []byte(`{"type":"chat.upsert","n":1}`),
		[]byte(`{"type":"message.upsert","n":2}`))
	keep := func(b []byte) bool { return !bytes.Contains(b, []byte("status.changed")) }
	if err := s.ResetSession(ctx, keep); err != nil {
		t.Fatal(err)
	}
	s.Enqueue(ctx, []byte(`{"type":"message.upsert","n":3}`)) // reset again with more queued
	if err := s.ResetSession(ctx, keep); err != nil {
		t.Fatal(err)
	}
	s.Close()

	s = openT(t, path, key)
	defer s.Close()
	var tables int
	s.DB().QueryRowContext(ctx, `SELECT count(*) FROM sqlite_master WHERE name LIKE 'whatsmeow_%'`).Scan(&tables)
	if _, ok, _ := s.Meta(ctx, "callback_secret"); ok || tables != 0 {
		t.Fatalf("session survived: secret kept %v, %d session tables", ok, tables)
	}
	if depth, _ := s.OutboxDepth(ctx); depth != 0 {
		t.Fatalf("outbox %d", depth)
	}
	if n, _ := s.CarryoverDepth(ctx); n != 3 {
		t.Fatalf("carryover %d", n)
	}
	if err := s.EnqueueReleasingCarryover(ctx, []byte(`{"type":"status.changed","status":"connected","new":1}`)); err != nil {
		t.Fatal(err)
	}
	pending, _ := s.Pending(ctx, 10)
	var order []string
	for _, e := range pending {
		order = append(order, string(e.Body))
	}
	want := []string{`{"type":"status.changed","status":"connected","new":1}`, `{"type":"chat.upsert","n":1}`,
		`{"type":"message.upsert","n":2}`, `{"type":"message.upsert","n":3}`}
	if strings.Join(order, "|") != strings.Join(want, "|") {
		t.Fatalf("order %v", order)
	}
	if n, _ := s.CarryoverDepth(ctx); n != 0 {
		t.Fatalf("carryover not released: %d", n)
	}
}
