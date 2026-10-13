package server

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"services/comms-connector/internal/rails"
	"services/comms-connector/internal/sig"
)

// fakeRails mirrors what Internal::Comms::EventsController and CommsEvents
// do with a connector's request: verify the per-connection signature
// (connection, method, path, time, nonce, body), refuse a replayed nonce,
// apply sequenced events exactly once and in order, refuse a gap with 409
// sequence_gap and the committed number, refuse an event from any pairing
// attempt but the current one (409 stale_attempt; a sequenced lifecycle
// event from an old attempt is acknowledged as skipped), answer 410
// connection_revoked for a disconnected connection, and keep the
// connection's status.
// The real endpoint is driven end to end by
// test/integration/comms_whatsapp_connector_test.rb.
type fakeRails struct {
	t       *testing.T
	mu      sync.Mutex
	down    bool
	secret  map[string]string
	attempt map[string]int64
	revoked map[string]bool
	nonces  map[string]bool
	seq     map[string]int64
	status  map[string]string
	qrs     map[string][]string
	events  map[string][]map[string]any
	stale   map[string]int // events refused or skipped as another attempt's
	raw     []string       // every body received, for canary checks
	srv     *httptest.Server
}

func newFakeRails(t *testing.T) *fakeRails {
	f := &fakeRails{t: t, secret: map[string]string{}, attempt: map[string]int64{}, revoked: map[string]bool{},
		nonces: map[string]bool{}, seq: map[string]int64{}, status: map[string]string{}, qrs: map[string][]string{},
		events: map[string][]map[string]any{}, stale: map[string]int{}}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeRails) client(t *testing.T) *rails.Client {
	c, err := rails.New(f.srv.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// expect registers a connection the way Rails creates one: status pairing,
// attempt 1.
func (f *fakeRails) expect(ref, secret string) {
	f.expectAttempt(ref, secret, 1)
}

// expectAttempt is Rails after the owner (re)started pairing: status
// pairing, and only events stamped with this attempt are accepted.
func (f *fakeRails) expectAttempt(ref, secret string, attempt int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.secret[ref], f.status[ref], f.attempt[ref] = secret, "pairing", attempt
}

// revoke is Rails after a disconnect whose unpair never reached the
// connector: the connection is revoked and its secret erased.
func (f *fakeRails) revoke(ref string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.revoked[ref], f.status[ref] = true, "revoked"
	delete(f.secret, ref)
}

func (f *fakeRails) setDown(down bool) {
	f.mu.Lock()
	f.down = down
	f.mu.Unlock()
}

func reply(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func (f *fakeRails) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.down {
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	parts := strings.Split(r.URL.Path, "/")
	if len(parts) != 6 || parts[4] == "" || r.URL.Path != rails.EventsPath(parts[4]) {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	ref := parts[4]
	body, _ := io.ReadAll(r.Body)
	f.raw = append(f.raw, string(body))
	if f.revoked[ref] {
		reply(w, 410, map[string]string{"error": "connection_revoked"})
		return
	}
	secret, ok := f.secret[ref]
	ts, nonce := r.Header.Get(sig.HeaderTimestamp), r.Header.Get(sig.HeaderNonce)
	if !ok || r.Header.Get(sig.HeaderConnection) != ref ||
		r.Header.Get(sig.HeaderSignature) != sig.SignEvent([]byte(secret), ref, r.Method, r.URL.Path, ts, nonce, body) {
		reply(w, 401, map[string]string{"error": "bad_signature"})
		return
	}
	if at, _ := strconv.ParseInt(ts, 10, 64); time.Since(time.Unix(at, 0)).Abs() > 300*time.Second {
		reply(w, 401, map[string]string{"error": "stale_timestamp"})
		return
	}
	var ev map[string]any
	dec := json.NewDecoder(strings.NewReader(string(body)))
	dec.UseNumber()
	if dec.Decode(&ev) != nil {
		reply(w, 400, map[string]string{"error": "bad_json"})
		return
	}
	var seq int64
	if n, ok := ev["seq"].(json.Number); ok {
		seq, _ = n.Int64()
		if seq <= f.seq[ref] {
			reply(w, 200, map[string]int64{"committed_seq": f.seq[ref]})
			return
		}
		if seq > f.seq[ref]+1 {
			reply(w, 409, map[string]any{"error": "sequence_gap", "committed_seq": f.seq[ref]})
			return
		}
	}
	if f.nonces[nonce] {
		reply(w, 401, map[string]string{"error": "replayed_nonce"})
		return
	}
	if n, ok := ev["attempt"].(json.Number); !ok || n.String() != strconv.FormatInt(f.attempt[ref], 10) {
		f.stale[ref]++
		lifecycle := ev["type"] == "pairing.qr" || ev["type"] == "status.changed"
		if seq > 0 && lifecycle {
			f.nonces[nonce] = true
			f.seq[ref] = seq
			reply(w, 200, map[string]any{"committed_seq": seq, "skipped": "stale_attempt"})
			return
		}
		reply(w, 409, map[string]string{"error": "stale_attempt"})
		return
	}
	switch ev["type"] {
	case "pairing.qr":
		if f.status[ref] != "pairing" {
			reply(w, 409, map[string]string{"error": "connection_not_accepting"})
			return
		}
		f.qrs[ref] = append(f.qrs[ref], ev["code"].(string))
	case "status.changed":
		switch ev["status"] {
		case "connected":
			f.status[ref] = "connected"
		case "logged_out":
			f.status[ref] = "reauthorizing"
		}
	case "chat.upsert", "message.upsert":
		if f.status[ref] != "connected" {
			reply(w, 409, map[string]string{"error": "connection_not_accepting"})
			return
		}
	default:
		reply(w, 422, map[string]string{"error": "unknown_event"})
		return
	}
	f.nonces[nonce] = true
	f.events[ref] = append(f.events[ref], ev)
	if seq > 0 {
		f.seq[ref] = seq
		reply(w, 200, map[string]int64{"committed_seq": seq})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (f *fakeRails) snapshot(ref string) (status string, qrs []string, events []map[string]any, committed int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.status[ref], append([]string(nil), f.qrs[ref]...), append([]map[string]any(nil), f.events[ref]...), f.seq[ref]
}

func (f *fakeRails) staleCount(ref string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.stale[ref]
}

// messages counts message.upsert items received for ref, by provider id.
func (f *fakeRails) messages(ref string) map[string]int {
	_, _, events, _ := f.snapshot(ref)
	out := map[string]int{}
	for _, ev := range events {
		if ev["type"] != "message.upsert" {
			continue
		}
		for _, m := range ev["messages"].([]any) {
			out[m.(map[string]any)["provider_message_id"].(string)]++
		}
	}
	return out
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}
