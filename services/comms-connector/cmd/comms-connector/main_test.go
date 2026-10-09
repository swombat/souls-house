package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"services/comms-connector/internal/keys"
	"services/comms-connector/internal/store"
	"services/comms-connector/internal/ticket"
)

const (
	testRef    = "conn-main0001"
	testSecret = "main-test-ticket-secret-0123456789abcdef"
)

func freeAddr(t *testing.T) string {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	a := ln.Addr().String()
	ln.Close()
	return a
}

func setEnv(t *testing.T, kek []byte, consumeURL string) {
	t.Setenv("COMMS_KEK", base64.StdEncoding.EncodeToString(kek))
	t.Setenv("COMMS_TICKET_SECRET", testSecret)
	t.Setenv("COMMS_CONSUME_URL", consumeURL)
	t.Setenv("GOTRACEBACK", "")
}

func TestRefusesToStart(t *testing.T) {
	kek := make([]byte, 32)
	rand.Read(kek)
	dir := t.TempDir()
	args := []string{"-data", dir, "-listen", freeAddr(t), "-connection", testRef, "-key-generation", "1", "-init"}
	cases := map[string]func(){
		"no KEK":            func() { os.Unsetenv("COMMS_KEK") },
		"short KEK":         func() { os.Setenv("COMMS_KEK", base64.StdEncoding.EncodeToString(kek[:31])) },
		"no ticket secret":  func() { os.Unsetenv("COMMS_TICKET_SECRET") },
		"short secret":      func() { os.Setenv("COMMS_TICKET_SECRET", "short") },
		"no consume URL":    func() { os.Unsetenv("COMMS_CONSUME_URL") },
		"GOTRACEBACK=crash": func() { os.Setenv("GOTRACEBACK", "crash") },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			setEnv(t, kek, "http://127.0.0.1:1")
			mutate()
			if code := run(args); code != 2 {
				t.Fatalf("exit %d, want 2", code)
			}
		})
	}
	setEnv(t, kek, "http://127.0.0.1:1")
	for name, a := range map[string][]string{
		"bad ref":             {"-data", dir, "-listen", freeAddr(t), "-connection", "../x", "-key-generation", "1"},
		"no generation":       {"-data", dir, "-listen", freeAddr(t), "-connection", testRef},
		"no listen":           {"-data", dir, "-connection", testRef, "-key-generation", "1"},
		"no DEK without init": {"-data", dir, "-listen", freeAddr(t), "-connection", testRef, "-key-generation", "1"},
	} {
		if code := run(a); code != 2 {
			t.Errorf("%s: exit %d, want 2", name, code)
		}
	}
}

type rig struct {
	t      *testing.T
	secret ticket.Secret
	addr   string
}

func (r *rig) read(path, q, tid string) (int, string) {
	canon, _, _ := ticket.CanonicalQuery(q)
	h, _ := ticket.Sign(r.secret, ticket.Claims{
		TicketID: tid, ConnectionRef: testRef, KeyGeneration: 1, AccessEpoch: 1,
		GrantID: "g-1", Principal: "agent:1", APIKeyID: "k-1", RunID: "run-1",
		ExpiresAt: time.Now().Add(20 * time.Second).Unix(), RequestDigest: ticket.Digest("GET", path, canon),
	})
	u := "http://" + r.addr + path
	if q != "" {
		u += "?" + q
	}
	req, _ := http.NewRequest("GET", u, nil)
	req.Header.Set("X-Comms-Ticket", h)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, ""
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func (r *rig) waitReady(n *int) {
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		*n++
		code, body := r.read("/v1/connections/"+testRef+"/messages", "chat=chat-0002&limit=200", fmt.Sprintf("ticket-ready%04d", *n))
		if code == 200 && strings.Count(body, `"id"`) == 20 {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	r.t.Fatal("connector did not become ready")
}

// TestBinaryLifecycle starts the real run() with -init and the synthetic
// provider, checks that a second worker on the same connection is refused,
// stops it with SIGTERM, restarts it without -init, and checks that rows and
// the access log survived the restart.
func TestBinaryLifecycle(t *testing.T) {
	kek := make([]byte, 32)
	rand.Read(kek)
	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"allowed":true}`)
	}))
	defer rails.Close()
	setEnv(t, kek, rails.URL)
	dir := t.TempDir()
	secret, _ := ticket.NewSecret(testSecret)
	r := &rig{t: t, secret: secret, addr: freeAddr(t)}
	base := []string{"-data", dir, "-listen", r.addr, "-connection", testRef, "-key-generation", "1", "-provider", "synthetic"}

	n := 0
	for round := 0; round < 2; round++ {
		args := base
		if round == 0 {
			args = append(append([]string{}, base...), "-init")
		}
		done := make(chan int, 1)
		go func() { done <- run(args) }()
		r.waitReady(&n)

		// A second worker on the same connection exits with code 2 and
		// never reaches the store.
		second := append([]string{}, base...)
		second[3] = freeAddr(t)
		if code := run(second); code != 2 {
			t.Fatalf("round %d: second worker exit %d, want 2", round, code)
		}

		syscall.Kill(os.Getpid(), syscall.SIGTERM)
		select {
		case code := <-done:
			if code != 0 {
				t.Fatalf("round %d: exit %d", round, code)
			}
		case <-time.After(15 * time.Second):
			t.Fatal("did not stop on SIGTERM")
		}
	}

	// After two lifetimes: the -init refusal on an existing store, and an
	// intact access log with one entry per released read.
	if code := run(append(append([]string{}, base...), "-init")); code != 2 {
		t.Fatalf("-init on an existing connection: exit %d, want 2", code)
	}
	dek, err := keys.LoadDEK(dir, kek, testRef, 1)
	if err != nil {
		t.Fatal(err)
	}
	dbKey, _ := keys.SQLCipherKey(dek)
	st, err := store.Open(context.Background(), filepath.Join(dir, testRef, "store-1.db"), dbKey)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	log, err := st.AccessLog(context.Background())
	if err != nil || store.VerifyChain(log) != nil {
		t.Fatal("access log broken after restart")
	}
	released := 0
	for _, e := range log {
		if e.RowCount == 20 {
			released++
		}
	}
	if released < 2 {
		t.Fatalf("expected at least one logged release per lifetime, got %d", released)
	}
	msgs, _ := st.ListMessages(context.Background(), "chat-0000", 200)
	if len(msgs) != 20 {
		t.Fatalf("messages after restart: %d", len(msgs))
	}
	// Permissions: everything in the connection dir is owner-only.
	ents, _ := os.ReadDir(filepath.Join(dir, testRef))
	for _, e := range ents {
		fi, _ := e.Info()
		if fi.Mode().Perm()&0o077 != 0 {
			t.Errorf("%s has mode %v", e.Name(), fi.Mode().Perm())
		}
	}
}
