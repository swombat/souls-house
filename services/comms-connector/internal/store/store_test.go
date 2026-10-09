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
	"time"

	"services/comms-connector/internal/provider"
)

const canary = "CANARY-COMMS-store-7f3a"

func randKey(t *testing.T) []byte {
	t.Helper()
	k := make([]byte, 32)
	rand.Read(k)
	return k
}

func synthetic() provider.Synthetic {
	s := provider.DefaultSynthetic()
	s.Marker = canary
	return s
}

func openT(t *testing.T, path string, key []byte) *Store {
	t.Helper()
	s, err := Open(context.Background(), path, key)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	return s
}

func count(t *testing.T, s *Store, table string) int {
	t.Helper()
	var n int
	if err := s.db.QueryRow("SELECT count(*) FROM " + table).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// TestRestartSurvivesReopen is the ConnectHook trap test: a hook-keyed
// database works fresh and fails on reopen, so this test must reopen.
func TestRestartSurvivesReopen(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "store-1.db")
	key := randKey(t)
	s := openT(t, path, key)
	if err := synthetic().Run(ctx, s); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AppendAccess(ctx, AccessEntry{Principal: "p", APIKeyID: "k", RunID: "r", TicketID: "t-00000001", GrantID: "g", KeyGeneration: 1, Scope: "chats:max=200", RowCount: 3}); err != nil {
		t.Fatal(err)
	}
	wantMsgs := count(t, s, "messages")
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	for i := 0; i < 2; i++ { // reopen twice: fresh pool each time
		s2 := openT(t, path, key)
		if got := count(t, s2, "messages"); got != wantMsgs || got != 60 {
			t.Fatalf("reopen %d: messages = %d, want %d", i, got, wantMsgs)
		}
		msgs, err := s2.ListMessages(ctx, provider.ChatID(1), 5)
		if err != nil || len(msgs) != 5 || !strings.Contains(msgs[0].Body, canary) {
			t.Fatalf("reopen %d: read back failed", i)
		}
		log, err := s2.AccessLog(ctx)
		if err != nil || len(log) != 1 || VerifyChain(log) != nil {
			t.Fatalf("reopen %d: access log not intact", i)
		}
		// Re-running the deterministic provider is idempotent.
		if err := synthetic().Run(ctx, s2); err != nil || count(t, s2, "messages") != wantMsgs {
			t.Fatalf("reopen %d: provider re-run not idempotent", i)
		}
		s2.Close()
	}
}

func TestWrongKeyFails(t *testing.T) {
	path := filepath.Join(t.TempDir(), "store-1.db")
	key := randKey(t)
	s := openT(t, path, key)
	synthetic().Run(context.Background(), s)
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
	path := filepath.Join(t.TempDir(), "store-1.db")
	key := randKey(t)
	s := openT(t, path, key)
	big := provider.Synthetic{Chats: 20, MessagesPerChat: 100, Marker: canary, Base: time.Unix(1_700_000_000, 0)}
	if err := big.Run(ctx, s); err != nil {
		t.Fatal(err)
	}
	// A sort large enough to want temp space, while the WAL is live.
	rows, err := s.db.Query("SELECT body FROM messages ORDER BY body || sender_name DESC")
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
	provider.Inject(ctx, s, nil, []provider.Message{{ID: "m-x", ChatID: provider.ChatID(0), Body: canary + "-late", SentAt: time.Now()}})
	scanFiles(t, path, key, true)
	s.Close()
}

func TestTempStoreOnEveryPooledConnection(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "store-1.db")
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
	path := filepath.Join(t.TempDir(), "store-1.db")
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

func appendN(t *testing.T, s *Store, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		_, err := s.AppendAccess(context.Background(), AccessEntry{
			Principal: "agent:1", APIKeyID: "key-1", RunID: "run-1",
			TicketID: fmt.Sprintf("ticket-%08d", i), GrantID: "grant-1",
			AccessEpoch: 4, KeyGeneration: 1, Scope: "messages:chat=chat-0001:limit=5", RowCount: 5,
		})
		if err != nil {
			t.Fatal(err)
		}
	}
}

func TestHashChain(t *testing.T) {
	ctx := context.Background()
	s := openT(t, filepath.Join(t.TempDir(), "store-1.db"), randKey(t))
	defer s.Close()
	appendN(t, s, 5)
	log, err := s.AccessLog(ctx)
	if err != nil || len(log) != 5 {
		t.Fatal("read log")
	}
	if err := VerifyChain(log); err != nil {
		t.Fatalf("intact chain rejected: %v", err)
	}
	if !bytes.Equal(log[0].PrevHash, GenesisHash) {
		t.Fatal("first entry does not link to genesis")
	}
	for i := 1; i < len(log); i++ {
		if !bytes.Equal(log[i].PrevHash, log[i-1].Hash) {
			t.Fatalf("entry %d does not link", i+1)
		}
	}

	tamper := func(name string, f func(es []AccessEntry) []AccessEntry) {
		es := make([]AccessEntry, len(log))
		copy(es, log)
		if VerifyChain(f(es)) == nil {
			t.Errorf("tamper %q not detected", name)
		}
	}
	tamper("row count", func(es []AccessEntry) []AccessEntry { es[2].RowCount = 500; return es })
	tamper("principal", func(es []AccessEntry) []AccessEntry { es[1].Principal = "agent:2"; return es })
	tamper("scope", func(es []AccessEntry) []AccessEntry { es[3].Scope = "chats:max=200"; return es })
	tamper("time", func(es []AccessEntry) []AccessEntry { es[0].At = es[0].At.Add(time.Second); return es })
	tamper("delete middle", func(es []AccessEntry) []AccessEntry { return append(es[:2], es[3:]...) })
	tamper("reorder", func(es []AccessEntry) []AccessEntry { es[1], es[2] = es[2], es[1]; return es })
	tamper("rehash one", func(es []AccessEntry) []AccessEntry {
		es[2].RowCount = 0
		es[2].Hash = EntryHash(es[2].PrevHash, es[2])
		return es
	})

	// Tampering in the database itself is caught on read-back.
	if _, err := s.db.Exec("UPDATE access_log SET row_count = 999 WHERE seq = 3"); err != nil {
		t.Fatal(err)
	}
	log2, _ := s.AccessLog(ctx)
	if err := VerifyChain(log2); err == nil || !strings.Contains(err.Error(), "seq 3") {
		t.Fatalf("DB tamper not detected at seq 3: %v", err)
	}
}

func TestAppendFailureWritesNothing(t *testing.T) {
	ctx := context.Background()
	s := openT(t, filepath.Join(t.TempDir(), "store-1.db"), randKey(t))
	defer s.Close()
	appendN(t, s, 1)
	if _, err := s.db.Exec(`CREATE TRIGGER fail_log BEFORE INSERT ON access_log BEGIN SELECT RAISE(ABORT, 'forced'); END`); err != nil {
		t.Fatal(err)
	}
	_, err := s.AppendAccess(ctx, AccessEntry{TicketID: "ticket-zz000001", Scope: "chats:max=200"})
	if !errors.Is(err, ErrAccessLog) || strings.Contains(err.Error(), "forced") {
		t.Fatalf("got %v", err)
	}
	if n := count(t, s, "access_log"); n != 1 {
		t.Fatalf("access_log has %d rows after failed append", n)
	}
}

func TestDuplicateTicketRefusedByLog(t *testing.T) {
	s := openT(t, filepath.Join(t.TempDir(), "store-1.db"), randKey(t))
	defer s.Close()
	e := AccessEntry{TicketID: "ticket-dup00001", Scope: "chats:max=200"}
	if _, err := s.AppendAccess(context.Background(), e); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AppendAccess(context.Background(), e); !errors.Is(err, ErrAccessLog) {
		t.Fatal("same ticket logged twice")
	}
}
