package api_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"services/comms-connector/internal/api"
	"services/comms-connector/internal/keys"
	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/store"
	"services/comms-connector/internal/ticket"
)

const (
	ref       = "conn-0123abcd"
	otherRef  = "conn-9999zzzz"
	gen       = uint64(1)
	canary    = "CANARY-COMMS-api-51c2"
	secretStr = "test-ticket-secret-0123456789abcdef-CANARYSECRET"
)

// ---- fake Rails consume endpoint ----

type fakeRails struct {
	mu      sync.Mutex
	calls   int
	badSig  int
	seen    map[string]int
	respond func(w http.ResponseWriter, ticketID string, nth int)
	secret  ticket.Secret
	srv     *httptest.Server
	release chan struct{}
}

func allow(w http.ResponseWriter, _ string, _ int) {
	w.Header().Set("Content-Type", "application/json")
	io.WriteString(w, `{"allowed":true}`)
}

func newFakeRails(t *testing.T, secret ticket.Secret) *fakeRails {
	f := &fakeRails{seen: map[string]int{}, respond: allow, secret: secret, release: make(chan struct{})}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /internal/comms/tickets/{id}/consume", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		body, _ := io.ReadAll(r.Body)
		f.mu.Lock()
		f.calls++
		f.seen[id]++
		nth := f.seen[id]
		ok := r.Header.Get(ticket.SignatureHeader) == ticket.ConsumeSignature(secret, id, body)
		var req struct{ Ticket string }
		if json.Unmarshal(body, &req) != nil || req.Ticket == "" {
			ok = false
		}
		if !ok {
			f.badSig++
		}
		respond := f.respond
		f.mu.Unlock()
		if !ok {
			http.Error(w, "bad signature", http.StatusUnauthorized)
			return
		}
		respond(w, id, nth)
	})
	mux.HandleFunc("POST /elsewhere", func(w http.ResponseWriter, r *http.Request) { allow(w, "", 1) })
	f.srv = httptest.NewServer(mux)
	t.Cleanup(func() { close(f.release); f.srv.Close() })
	return f
}

func (f *fakeRails) set(fn func(w http.ResponseWriter, ticketID string, nth int)) {
	f.mu.Lock()
	f.respond = fn
	f.mu.Unlock()
}

func (f *fakeRails) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

// ---- connector under test ----

type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}
func (s *syncBuf) String() string { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

type env struct {
	t      *testing.T
	kek    []byte
	dbKey  []byte
	dbPath string
	st     *store.Store
	secret ticket.Secret
	rails  *fakeRails
	logs   *syncBuf
	url    string
	reader api.Reader
}

type opt func(*env, *api.Config)

func newEnv(t *testing.T, opts ...opt) *env {
	t.Helper()
	e := &env{t: t, logs: &syncBuf{}}
	dataDir := t.TempDir()
	e.kek = make([]byte, 32)
	rand.Read(e.kek)
	connDir, _ := keys.ConnDir(dataDir, ref)
	os.MkdirAll(connDir, 0o700)
	dek, err := keys.CreateDEK(dataDir, e.kek, ref, gen)
	if err != nil {
		t.Fatal(err)
	}
	e.dbKey, _ = keys.SQLCipherKey(dek)
	e.dbPath = filepath.Join(connDir, "store-1.db")
	e.st, err = store.Open(context.Background(), e.dbPath, e.dbKey)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { e.st.Close() })
	syn := provider.DefaultSynthetic()
	syn.Marker = canary
	if err := syn.Run(context.Background(), e.st); err != nil {
		t.Fatal(err)
	}
	e.secret, _ = ticket.NewSecret(secretStr)
	e.rails = newFakeRails(t, e.secret)
	cons, err := ticket.NewConsumer(e.rails.srv.URL, e.secret, 300*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	logID, _ := keys.LogID(e.kek, ref)
	e.reader = e.st
	cfg := api.Config{
		ConnectionRef: ref,
		KeyGeneration: gen,
		Secret:        e.secret,
		Consumer:      cons,
		Log:           slog.New(slog.NewJSONHandler(e.logs, nil)),
		LogID:         logID,
	}
	for _, o := range opts {
		o(e, &cfg)
	}
	cfg.Store = e.reader
	srv := httptest.NewServer(api.New(cfg))
	t.Cleanup(srv.Close)
	e.url = srv.URL
	return e
}

func claims(tid, path, rawQuery string) ticket.Claims {
	canon, _, _ := ticket.CanonicalQuery(rawQuery)
	return ticket.Claims{
		TicketID:      tid,
		ConnectionRef: ref,
		KeyGeneration: gen,
		AccessEpoch:   7,
		GrantID:       "grant-42",
		Principal:     "agent:CANARY-COMMS-principal",
		APIKeyID:      "apikey-9",
		RunID:         "run-CANARY-COMMS-run",
		ExpiresAt:     time.Now().Add(30 * time.Second).Unix(),
		RequestDigest: ticket.Digest("GET", path, canon),
	}
}

func (e *env) mint(c ticket.Claims) string {
	h, err := ticket.Sign(e.secret, c)
	if err != nil {
		e.t.Fatal(err)
	}
	return h
}

type resp struct {
	status int
	body   string
	header http.Header
}

func (e *env) get(path, rawQuery string, tickets ...string) resp {
	e.t.Helper()
	u := e.url + path
	if rawQuery != "" {
		u += "?" + rawQuery
	}
	req, _ := http.NewRequest("GET", u, nil)
	for _, tk := range tickets {
		req.Header.Add(api.TicketHeader, tk)
	}
	r, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer r.Body.Close()
	b, _ := io.ReadAll(r.Body)
	if r.Header.Get("Cache-Control") != "no-store" {
		e.t.Errorf("%s: Cache-Control = %q", path, r.Header.Get("Cache-Control"))
	}
	return resp{r.StatusCode, string(b), r.Header}
}

func (e *env) logLen() int {
	e.t.Helper()
	l, err := e.st.AccessLog(context.Background())
	if err != nil {
		e.t.Fatal(err)
	}
	return len(l)
}

const (
	msgPath  = "/v1/connections/" + ref + "/messages"
	chatPath = "/v1/connections/" + ref + "/chats"
	q5       = "chat=chat-0001&limit=5"
)

// ---- tests ----

func TestValidReadReleasesRowsAndLogsOnce(t *testing.T) {
	e := newEnv(t)
	r := e.get(msgPath, q5, e.mint(claims("ticket-00000001", msgPath, q5)))
	if r.status != 200 {
		t.Fatalf("status %d body %q", r.status, r.body)
	}
	var out struct {
		Messages []struct{ ID, ChatID, Body string } `json:"messages"`
	}
	if err := json.Unmarshal([]byte(r.body), &out); err != nil || len(out.Messages) != 5 {
		t.Fatalf("decoded %d messages", len(out.Messages))
	}
	if !strings.Contains(out.Messages[0].Body, canary) {
		t.Fatal("expected synthetic content in a released read")
	}
	if e.rails.count() != 1 || e.rails.badSig != 0 {
		t.Fatalf("consume calls %d, bad signatures %d", e.rails.count(), e.rails.badSig)
	}
	log, _ := e.st.AccessLog(context.Background())
	if len(log) != 1 {
		t.Fatalf("access log entries = %d, want 1", len(log))
	}
	l := log[0]
	if l.TicketID != "ticket-00000001" || l.Principal != "agent:CANARY-COMMS-principal" || l.APIKeyID != "apikey-9" ||
		l.RunID != "run-CANARY-COMMS-run" || l.GrantID != "grant-42" || l.AccessEpoch != 7 || l.KeyGeneration != gen ||
		l.Scope != "messages:chat=chat-0001:limit=5" || l.RowCount != 5 {
		t.Fatalf("log entry = %+v", l)
	}
	if strings.Contains(l.Scope, canary) || store.VerifyChain(log) != nil {
		t.Fatal("log entry carries content or chain broken")
	}

	// The chats endpoint, and a query given in another order (canonicalised).
	r = e.get(chatPath, "", e.mint(claims("ticket-00000002", chatPath, "")))
	if r.status != 200 || strings.Count(r.body, `"id"`) != 3 {
		t.Fatalf("chats: %d %q", r.status, r.body)
	}
	r = e.get(msgPath, "limit=5&chat=chat-0001", e.mint(claims("ticket-00000003", msgPath, q5)))
	if r.status != 200 || e.logLen() != 3 {
		t.Fatalf("reordered query: %d, log %d", r.status, e.logLen())
	}
}

func assertRefused(t *testing.T, e *env, r resp, wantStatus int, wantConsume int, wantLog int) {
	t.Helper()
	if r.status != wantStatus {
		t.Errorf("status %d, want %d (body %q)", r.status, wantStatus, r.body)
	}
	for _, bad := range []string{canary, "CANARY", "chat-0001", "Synthetic", ref} {
		if strings.Contains(r.body, bad) {
			t.Errorf("refusal body contains %q", bad)
		}
	}
	switch r.body {
	case "forbidden\n", "unavailable\n", "internal error\n", "bad request\n", "not found\n", "method not allowed\n":
	default:
		t.Errorf("unexpected body %q", r.body)
	}
	if got := e.rails.count(); got != wantConsume {
		t.Errorf("consume calls %d, want %d", got, wantConsume)
	}
	if got := e.logLen(); got != wantLog {
		t.Errorf("access log entries %d, want %d", got, wantLog)
	}
}

func TestRefusedBeforeConsume(t *testing.T) {
	other, _ := ticket.NewSecret("another-secret-0123456789abcdef-xyz")
	cases := map[string]func(e *env) resp{
		"bad signature": func(e *env) resp {
			h, _ := ticket.Sign(other, claims("ticket-00000001", msgPath, q5))
			return e.get(msgPath, q5, h)
		},
		"flipped signature byte": func(e *env) resp {
			h := e.mint(claims("ticket-00000001", msgPath, q5))
			last := h[len(h)-2]
			repl := byte('A')
			if last == 'A' {
				repl = 'B'
			}
			return e.get(msgPath, q5, h[:len(h)-2]+string(repl)+h[len(h)-1:])
		},
		"payload swapped under old signature": func(e *env) resp {
			h1 := e.mint(claims("ticket-00000001", msgPath, q5))
			c := claims("ticket-00000001", msgPath, "chat=chat-0002&limit=5")
			h2 := e.mint(c)
			p2, _, _ := strings.Cut(h2, ".")
			_, s1, _ := strings.Cut(h1, ".")
			return e.get(msgPath, "chat=chat-0002&limit=5", p2+"."+s1)
		},
		"expired": func(e *env) resp {
			c := claims("ticket-00000001", msgPath, q5)
			c.ExpiresAt = time.Now().Add(-1 * time.Second).Unix()
			return e.get(msgPath, q5, e.mint(c))
		},
		"lifetime over 60s": func(e *env) resp {
			c := claims("ticket-00000001", msgPath, q5)
			c.ExpiresAt = time.Now().Add(120 * time.Second).Unix()
			return e.get(msgPath, q5, e.mint(c))
		},
		"wrong connection": func(e *env) resp {
			c := claims("ticket-00000001", msgPath, q5)
			c.ConnectionRef = otherRef
			return e.get(msgPath, q5, e.mint(c))
		},
		"wrong key generation": func(e *env) resp {
			c := claims("ticket-00000001", msgPath, q5)
			c.KeyGeneration = 2
			return e.get(msgPath, q5, e.mint(c))
		},
		"digest: other chat": func(e *env) resp {
			return e.get(msgPath, "chat=chat-0002&limit=5", e.mint(claims("ticket-00000001", msgPath, q5)))
		},
		"digest: other limit": func(e *env) resp {
			return e.get(msgPath, "chat=chat-0001&limit=6", e.mint(claims("ticket-00000001", msgPath, q5)))
		},
		"digest: other endpoint": func(e *env) resp {
			return e.get(chatPath, "", e.mint(claims("ticket-00000001", msgPath, q5)))
		},
		"missing ticket": func(e *env) resp { return e.get(msgPath, q5) },
		"two tickets": func(e *env) resp {
			h := e.mint(claims("ticket-00000001", msgPath, q5))
			return e.get(msgPath, q5, h, h)
		},
		"malformed ticket": func(e *env) resp { return e.get(msgPath, q5, "not-a-ticket") },
		"unknown claim field": func(e *env) resp {
			c := claims("ticket-00000001", msgPath, q5)
			b, _ := json.Marshal(c)
			b = append(b[:len(b)-1], []byte(`,"extra":1}`)...)
			pb := base64.RawURLEncoding.EncodeToString(b)
			sig := signRaw(e.secret, pb)
			return e.get(msgPath, q5, pb+"."+sig)
		},
	}
	for name, fn := range cases {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t)
			assertRefused(t, e, fn(e), http.StatusForbidden, 0, 0)
		})
	}
}

// signRaw signs an arbitrary payload the way Rails would.
func signRaw(s ticket.Secret, payloadB64 string) string { return ticket.SignPayload(s, payloadB64) }

func TestRequestShapeRefusals(t *testing.T) {
	e := newEnv(t)
	tk := e.mint(claims("ticket-00000001", msgPath, q5))
	cases := []struct {
		path, query string
		status      int
	}{
		{"/v1/connections/" + otherRef + "/messages", q5, 404},
		{"/v1/connections/" + canary + "/messages", q5, 404},
		{"/v1/connections/" + ref + "/other", "", 404},
		{"/v1/connections/" + ref + "/messages/x", q5, 404},
		{"//v1/connections/" + ref + "/messages", q5, 404},
		{"/v1/connections/" + ref + "/%6dessages", q5, 404},
		{msgPath, "chat=chat-0001", 400},
		{msgPath, "chat=chat-0001&limit=0", 400},
		{msgPath, "chat=chat-0001&limit=201", 400},
		{msgPath, "chat=chat-0001&limit=+5", 400},
		{msgPath, "chat=chat-0001&limit=05", 400},
		{msgPath, "chat=chat-0001&chat=chat-0002&limit=5", 400},
		{msgPath, "chat=" + canary + "%00&limit=5", 400},
		{msgPath, q5 + "&x=1", 400},
		{chatPath, "x=1", 400},
		{msgPath, "chat=%zz&limit=5", 400},
	}
	for _, c := range cases {
		r := e.get(c.path, c.query, tk)
		if r.status != c.status {
			t.Errorf("%s?%s: status %d, want %d", c.path, c.query, r.status, c.status)
		}
		if strings.Contains(r.body, canary) || r.header.Get("Location") != "" {
			t.Errorf("%s?%s: echoed input", c.path, c.query)
		}
	}
	req, _ := http.NewRequest("POST", e.url+msgPath+"?"+q5, nil)
	req.Header.Set(api.TicketHeader, tk)
	r, _ := http.DefaultClient.Do(req)
	r.Body.Close()
	if r.StatusCode != 405 || r.Header.Get("Cache-Control") != "no-store" {
		t.Errorf("POST: %d", r.StatusCode)
	}
	if e.rails.count() != 0 || e.logLen() != 0 {
		t.Fatal("shape refusal reached consume or log")
	}
}

func TestConsumeRefusals(t *testing.T) {
	jsonResp := func(status int, body string) func(http.ResponseWriter, string, int) {
		return func(w http.ResponseWriter, _ string, _ int) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			io.WriteString(w, body)
		}
	}
	cases := map[string]struct {
		fn     func(http.ResponseWriter, string, int)
		status int
	}{
		"allowed false":   {jsonResp(200, `{"allowed":false}`), 403},
		"403":             {jsonResp(403, `{"allowed":true}`), 403},
		"500":             {jsonResp(500, `{"allowed":true}`), 403},
		"201":             {jsonResp(201, `{"allowed":true}`), 403},
		"empty body":      {jsonResp(200, ``), 403},
		"truncated json":  {jsonResp(200, `{"allowed":true`), 403},
		"string true":     {jsonResp(200, `{"allowed":"true"}`), 403},
		"null":            {jsonResp(200, `null`), 403},
		"missing field":   {jsonResp(200, `{}`), 403},
		"extra field":     {jsonResp(200, `{"allowed":true,"note":1}`), 403},
		"trailing object": {jsonResp(200, `{"allowed":true}{"allowed":true}`), 403},
		"array":           {jsonResp(200, `[true]`), 403},
		"bare true":       {jsonResp(200, `true`), 403},
		"oversized":       {jsonResp(200, `{"allowed":true}`+strings.Repeat(" ", 2000)), 403},
		"wrong content type": {func(w http.ResponseWriter, _ string, _ int) {
			w.Header().Set("Content-Type", "text/plain")
			io.WriteString(w, `{"allowed":true}`)
		}, 403},
		"redirect to an allowing endpoint": {func(w http.ResponseWriter, _ string, _ int) {
			w.Header().Set("Location", "/elsewhere")
			w.WriteHeader(http.StatusTemporaryRedirect)
		}, 403},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t)
			e.rails.set(c.fn)
			r := e.get(msgPath, q5, e.mint(claims("ticket-00000001", msgPath, q5)))
			assertRefused(t, e, r, c.status, 1, 0)
		})
	}
}

func TestConsumeTimeout(t *testing.T) {
	e := newEnv(t)
	e.rails.set(func(w http.ResponseWriter, id string, n int) {
		select {
		case <-e.rails.release:
		case <-time.After(3 * time.Second):
		}
		allow(w, id, n)
	})
	start := time.Now()
	r := e.get(msgPath, q5, e.mint(claims("ticket-00000001", msgPath, q5)))
	if time.Since(start) > 2*time.Second {
		t.Fatal("consume timeout not enforced")
	}
	assertRefused(t, e, r, http.StatusServiceUnavailable, 1, 0)
}

func TestConsumeConnectionError(t *testing.T) {
	dead := httptest.NewServer(http.NotFoundHandler())
	deadURL := dead.URL
	dead.Close()
	e := newEnv(t, func(e *env, c *api.Config) {
		cons, _ := ticket.NewConsumer(deadURL, e.secret, 300*time.Millisecond)
		c.Consumer = cons
	})
	r := e.get(msgPath, q5, e.mint(claims("ticket-00000001", msgPath, q5)))
	assertRefused(t, e, r, http.StatusServiceUnavailable, 0, 0)
}

func TestReplayRefused(t *testing.T) {
	e := newEnv(t)
	// Rails semantics: the first consume of a ticket is allowed, later ones are not.
	e.rails.set(func(w http.ResponseWriter, id string, nth int) {
		w.Header().Set("Content-Type", "application/json")
		if nth == 1 {
			io.WriteString(w, `{"allowed":true}`)
			return
		}
		io.WriteString(w, `{"allowed":false}`)
	})
	tk := e.mint(claims("ticket-00000001", msgPath, q5))
	if r := e.get(msgPath, q5, tk); r.status != 200 {
		t.Fatalf("first use: %d", r.status)
	}
	r := e.get(msgPath, q5, tk)
	assertRefused(t, e, r, http.StatusForbidden, 2, 1)
}

// If Rails wrongly allowed the same ticket twice, the access log's unique
// ticket_id makes the second append fail, so nothing is released.
func TestReplayRefusedLocallyIfRailsAllowsTwice(t *testing.T) {
	e := newEnv(t)
	tk := e.mint(claims("ticket-00000001", msgPath, q5))
	if r := e.get(msgPath, q5, tk); r.status != 200 {
		t.Fatalf("first use: %d", r.status)
	}
	r := e.get(msgPath, q5, tk)
	assertRefused(t, e, r, http.StatusInternalServerError, 2, 1)
}

type failingAppend struct{ *store.Store }

func (failingAppend) AppendAccess(context.Context, store.AccessEntry) (store.AccessEntry, error) {
	return store.AccessEntry{}, errors.New("forced failure " + canary)
}

// closingAppend closes the store (and with it the log) just before appending.
type closingAppend struct{ *store.Store }

func (c closingAppend) AppendAccess(ctx context.Context, e store.AccessEntry) (store.AccessEntry, error) {
	c.Store.Close()
	return c.Store.AppendAccess(ctx, e)
}

func TestAccessLogFailureReleasesNothing(t *testing.T) {
	for name, wrap := range map[string]func(*store.Store) api.Reader{
		"failing writer": func(s *store.Store) api.Reader { return failingAppend{s} },
		"closed log":     func(s *store.Store) api.Reader { return closingAppend{s} },
	} {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t, func(e *env, c *api.Config) { e.reader = wrap(e.st) })
			for i, p := range []struct{ path, q string }{{msgPath, q5}, {chatPath, ""}} {
				r := e.get(p.path, p.q, e.mint(claims(fmt.Sprintf("ticket-%08d", i+1), p.path, p.q)))
				if r.status != 500 || r.body != "internal error\n" {
					t.Fatalf("%s: status %d body %q", p.path, r.status, r.body)
				}
				if strings.Contains(r.body, "Synthetic") || strings.Contains(r.body, canary) {
					t.Fatal("rows released after log failure")
				}
				if name == "closed log" {
					break // the store is closed after the first request
				}
			}
			if name == "failing writer" && e.logLen() != 0 {
				t.Fatal("log entry written")
			}
			if name == "closed log" {
				// Reopen the database to confirm nothing was logged.
				s2, err := store.Open(context.Background(), e.dbPath, e.dbKey)
				if err != nil {
					t.Fatal(err)
				}
				defer s2.Close()
				l, _ := s2.AccessLog(context.Background())
				if len(l) != 0 {
					t.Fatal("log entry written")
				}
			}
		})
	}
}

func TestSecretAndConsumerConfigRefused(t *testing.T) {
	if _, err := ticket.NewSecret(""); err == nil {
		t.Error("empty ticket secret accepted")
	}
	if _, err := ticket.NewSecret(strings.Repeat("x", 31)); err == nil {
		t.Error("short ticket secret accepted")
	}
	s, _ := ticket.NewSecret(secretStr)
	for _, u := range []string{"", "ftp://rails", "http://", "http://u:p@rails", "http://rails?x=1", "rails:3000"} {
		if _, err := ticket.NewConsumer(u, s, 0); err == nil {
			t.Errorf("consume URL %q accepted", u)
		}
	}
}

// Ensure the test helper and production agree on the MAC.
func TestSignPayloadMatchesSign(t *testing.T) {
	s, _ := ticket.NewSecret(secretStr)
	h, _ := ticket.Sign(s, claims("ticket-00000001", msgPath, q5))
	p, sig, _ := strings.Cut(h, ".")
	if ticket.SignPayload(s, p) != sig {
		t.Fatal("helper MAC differs")
	}
	if hex.EncodeToString([]byte(s.String())) == hex.EncodeToString([]byte(secretStr)) {
		t.Fatal("secret formats itself")
	}
}
