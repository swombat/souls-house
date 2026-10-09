package api_test

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"services/comms-connector/internal/api"
	"services/comms-connector/internal/keys"
	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/store"
	"services/comms-connector/internal/ticket"
)

// captureStderr redirects file descriptor 2 (Go and C writers alike) to a
// temp file for the duration of fn and returns what was written.
func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "stderr")
	if err != nil {
		t.Fatal(err)
	}
	saved, err := unix.Dup(2)
	if err != nil {
		t.Fatal(err)
	}
	if err := unix.Dup2(int(f.Fd()), 2); err != nil {
		t.Fatal(err)
	}
	func() {
		defer func() {
			unix.Dup2(saved, 2)
			unix.Close(saved)
		}()
		fn()
	}()
	b, _ := os.ReadFile(f.Name())
	return string(b)
}

// TestLogCanary runs the full read path, its refusals and its failures with
// canary content, principals and run IDs, through the real http.Server
// configuration, with the slog handler on stderr. Everything written to fd 2
// must be free of content, DSN, keys and secrets.
func TestLogCanary(t *testing.T) {
	var handlerOut syncBuf
	var e *env
	stderr := captureStderr(t, func() {
		e = newEnv(t, func(e *env, c *api.Config) {
			c.Log = slog.New(slog.NewJSONHandler(io.MultiWriter(os.Stderr, &handlerOut), nil))
		})
		// Serve through NewHTTPServer (discarded ErrorLog) instead of httptest.
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		cons, _ := ticket.NewConsumer(e.rails.srv.URL, e.secret, 300*time.Millisecond)
		logID, _ := keys.LogID(e.kek, ref)
		h := api.New(api.Config{
			ConnectionRef: ref, KeyGeneration: gen, Secret: e.secret, Consumer: cons, Store: e.st,
			Log: slog.New(slog.NewJSONHandler(io.MultiWriter(os.Stderr, &handlerOut), nil)), LogID: logID,
		})
		srv := api.NewHTTPServer("", h)
		go srv.Serve(ln)
		defer srv.Close()
		e.url = "http://" + ln.Addr().String()

		// Released reads.
		for i, q := range []string{q5, "chat=chat-0000&limit=200"} {
			tid := []string{"ticket-canary001", "ticket-canary002"}[i]
			if r := e.get(msgPath, q, e.mint(claims(tid, msgPath, q))); r.status != 200 || !strings.Contains(r.body, canary) {
				t.Fatalf("released read %d failed: %d", i, r.status)
			}
		}
		if r := e.get(chatPath, "", e.mint(claims("ticket-canary003", chatPath, ""))); r.status != 200 {
			t.Fatal("chats read failed")
		}
		// Refusals and failures.
		e.get(msgPath, q5, e.mint(claims("ticket-canary001", msgPath, q5))) // local replay -> 500
		e.get(msgPath, "chat=chat-0002&limit=5", e.mint(claims("ticket-canary004", msgPath, q5)))
		e.get("/v1/connections/"+canary+"/chats", "", "garbage-"+canary)
		e.get(msgPath, "chat="+canary+"&limit=5", "x")
		e.rails.set(func(w http.ResponseWriter, _ string, _ int) {
			w.WriteHeader(500)
			io.WriteString(w, "rails error page mentioning "+canary)
		})
		e.get(msgPath, q5, e.mint(claims("ticket-canary005", msgPath, q5)))
		// A panicking store: the panic value must not be printed.
		ph := api.New(api.Config{
			ConnectionRef: ref, KeyGeneration: gen, Secret: e.secret, Consumer: allowAll{}, Store: panicReader{e.st},
			Log: slog.New(slog.NewJSONHandler(io.MultiWriter(os.Stderr, &handlerOut), nil)), LogID: logID,
		})
		pln, _ := net.Listen("tcp", "127.0.0.1:0")
		psrv := api.NewHTTPServer("", ph)
		go psrv.Serve(pln)
		defer psrv.Close()
		u := e.url
		e.url = "http://" + pln.Addr().String()
		if r := e.get(chatPath, "", e.mint(claims("ticket-canary006", chatPath, ""))); r.status != 500 {
			t.Fatalf("panic path status %d", r.status)
		}
		e.url = u
		// Opening with a wrong key logs nothing either.
		bad := make([]byte, 32)
		if _, err := store.Open(context.Background(), e.dbPath, bad); err == nil {
			t.Fatal("wrong key opened")
		}
	})

	all := stderr + "\n" + handlerOut.String()
	if !strings.Contains(handlerOut.String(), `"msg":"read"`) || !strings.Contains(stderr, `"msg":"read"`) {
		t.Fatalf("capture did not see the slog output; stderr=%q", stderr)
	}
	needles := map[string]string{
		"canary":            "CANARY",
		"DSN key param":     "_key=",
		"DSN cipher param":  "_cipher",
		"raw key literal":   "x'",
		"sqlcipher key hex": hex.EncodeToString(e.dbKey),
		"KEK base64":        base64.StdEncoding.EncodeToString(e.kek),
		"KEK hex":           hex.EncodeToString(e.kek),
		"KEK raw":           string(e.kek),
		"ticket secret":     secretStr,
		"connection ref":    ref,
		"db path":           e.dbPath,
		"chat id":           "chat-000",
		"synthetic text":    "Synthetic",
		"principal":         "agent:",
		"grant":             "grant-42",
		"ticket id":         "ticket-canary",
		"panic":             "panic carrying",
		"goroutine trace":   "goroutine ",
	}
	for name, n := range needles {
		if strings.Contains(all, n) {
			t.Errorf("log output contains %s", name)
		}
	}
	// Fields are a small fixed set.
	for _, line := range strings.Split(strings.TrimSpace(handlerOut.String()), "\n") {
		for _, k := range []string{`"time"`, `"level"`, `"msg"`, `"conn"`, `"status"`, `"reason"`, `"rows"`, `"dur_ms"`} {
			line = strings.Replace(line, k+":", "", 1)
		}
		if strings.Count(line, `":`) != 0 {
			t.Errorf("unexpected log field in %q", line)
		}
	}
}

type allowAll struct{}

func (allowAll) Consume(context.Context, string, string) error { return nil }

type panicReader struct{ *store.Store }

func (panicReader) ListChats(context.Context, int) ([]provider.Chat, error) {
	panic("panic carrying " + canary)
}
