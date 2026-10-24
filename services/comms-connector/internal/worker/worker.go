// Package worker runs one connection: its lease, its encrypted store, its
// provider session, and the sender that delivers the store's outbox to
// Rails in order.
//
// Delivery (proposal 2026-10-11 §5a, which Rails already implements for
// every comms provider): each queued event goes out with a sequence number;
// Rails applies sequenced events exactly once and in order, answers with the
// highest sequence it has committed, and refuses a gap with 409
// sequence_gap and that number. Only an acknowledged event leaves the
// outbox. The wire sequence is the outbox row id plus an offset learned from
// Rails the first time: a fresh store sends its first event with a sequence
// far past anything committed, Rails answers sequence_gap with its committed
// number (writing nothing), and the offset is set so the first row follows
// it. A re-paired connection therefore never reuses a number Rails has seen.
//
// Every event also names its pairing attempt ("attempt": the callback secret
// version the start_pairing command carried; Rails bumps it on each
// restart). Rails refuses anything from another attempt, so an event still
// in flight from a pairing the owner restarted cannot change the
// connection.
//
// A connection Rails has revoked (a disconnect whose unpair never arrived)
// answers 410 connection_revoked; the worker then asks its manager to
// unpair it, which stops collection and deletes the store.
//
// QR codes are not queued: they are short-lived and are posted at once.
package worker

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"services/comms-connector/internal/keys"
	"services/comms-connector/internal/lease"
	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/rails"
	"services/comms-connector/internal/store"
)

const (
	StoreFile = "store.db"

	metaSecret        = "callback_secret"
	metaSecretVersion = "callback_secret_version"
	metaSeqOffset     = "seq_offset"

	// probeSeq is past anything Rails can have committed, so it always
	// draws a sequence_gap reply that names the committed number.
	probeSeq = int64(1) << 50
)

var (
	ErrStaleSecret = errors.New("callback secret version is older than the one held")
	ErrNoSecret    = errors.New("connection has no callback secret")
	// ErrStaleAttempt: a pair_phone command for another pairing attempt.
	ErrStaleAttempt = errors.New("command is for another pairing attempt")
	// ErrNoRequest: a pair_phone command that names no phone request.
	ErrNoRequest = errors.New("pair_phone names no request")
	// ErrStaleRequest: a pair_phone command older (by Rails' request
	// sequence) than one already accepted. Refused before anything is
	// cancelled.
	ErrStaleRequest = errors.New("pair_phone is older than an accepted request")
	// ErrNotPairing: a pair_phone command for a connection that is not pairing.
	ErrNotPairing = errors.New("connection is not pairing")
)

// Rails is what the worker needs from rails.Client.
type Rails interface {
	Post(ctx context.Context, ref string, secret []byte, body []byte) (rails.Reply, error)
}

type Config struct {
	DataDir  string
	Ref      string
	StoreKey []byte // COMMS_STORE_KEY; the worker derives its own key
	Rails    Rails
	Factory  provider.Factory
	Log      *slog.Logger // already carries the connection's log id
	// Backoff bounds for delivery retries.
	MinBackoff, MaxBackoff time.Duration
	// OnRevoked is called (once, on its own goroutine) when Rails answers
	// that the connection is revoked. The manager unpairs the worker.
	OnRevoked func(*Worker)
}

type Worker struct {
	cfg   Config
	dir   string
	lease *lease.Lease
	st    *store.Store

	mu      sync.Mutex
	secret  []byte
	attempt int64 // the secret version: which pairing attempt this is
	session provider.Session
	cancel  context.CancelFunc
	ctx     context.Context // the running session's; nil when stopped
	done    chan struct{}
	bg      sync.WaitGroup // phone code requests; Stop waits for them
	// phoneRequest is the latest pair_phone accepted for this session (its
	// Rails-minted request id), and phoneCancel cancels that request's
	// context. A result for any other request is not posted.
	phoneRequest string
	phoneCancel  context.CancelFunc
	// phoneSeq is the highest request sequence accepted by this worker.
	// Rails assigns sequences under its row lock and never resets them
	// (a restart continues them), so it only ever goes up; a command
	// arriving with a lower or equal one is older than what is running.
	phoneSeq int64
	wake     chan struct{}
	state    string // idle | pairing | connected | logged_out | not_paired
	revoked  sync.Once

	// refusals counts consecutive content refusals of the head event: any
	// other outcome of a delivery attempt (a transport failure, another
	// status) sets it back to zero. It is kept in memory only, so a process
	// restart also starts it again.
	refusedID int64
	refusals  int
}

// maxRefusals: an event Rails refuses as invalid (422) or too large (413)
// this many times in a row is dropped, so one poison event cannot stop
// every later message. The whole event goes, i.e. the whole batch of up to
// 200 chats or messages, valid ones included: Rails refuses a batch as a
// unit and the outbox does not split one. Its sequence number is never
// committed, so the next event draws a sequence_gap and the offset is
// relearned.
const maxRefusals = 5

// testHookBeforeLeaseRelease runs in Unpair after the store and directory
// are gone and before the lease is released (tests only).
var testHookBeforeLeaseRelease func()

// Open takes the connection's lease and opens (creating if needed) its store.
func Open(ctx context.Context, cfg Config) (*Worker, error) {
	if cfg.MinBackoff == 0 {
		cfg.MinBackoff = time.Second
	}
	if cfg.MaxBackoff == 0 {
		cfg.MaxBackoff = time.Minute
	}
	dir, err := keys.ConnDir(cfg.DataDir, cfg.Ref)
	if err != nil {
		return nil, err
	}
	leasePath, err := keys.LeasePath(cfg.DataDir, cfg.Ref)
	if err != nil {
		return nil, err
	}
	l, err := lease.Acquire(leasePath)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		l.Release()
		return nil, errors.New("connection directory could not be created")
	}
	k, err := keys.StoreKey(cfg.StoreKey, cfg.Ref)
	if err != nil {
		l.Release()
		return nil, err
	}
	st, err := store.Open(ctx, filepath.Join(dir, StoreFile), k)
	clear(k)
	if err != nil {
		l.Release()
		return nil, err
	}
	w := &Worker{cfg: cfg, dir: dir, lease: l, st: st, wake: make(chan struct{}, 1), state: "idle"}
	if v, ok, err := st.Meta(ctx, metaSecret); err == nil && ok {
		w.secret = []byte(v)
	}
	w.attempt = w.SecretVersion(ctx)
	return w, nil
}

// Ref is the connection this worker runs.
func (w *Worker) Ref() string { return w.cfg.Ref }

// Exists reports whether ref has a store on disk.
func Exists(dataDir, ref string) bool {
	dir, err := keys.ConnDir(dataDir, ref)
	if err != nil {
		return false
	}
	_, err = os.Stat(filepath.Join(dir, StoreFile))
	return err == nil
}

// SecretVersion is the version of the held callback secret (0 if none).
func (w *Worker) SecretVersion(ctx context.Context) int64 {
	v, ok, err := w.st.Meta(ctx, metaSecretVersion)
	if err != nil || !ok {
		return 0
	}
	n, _ := strconv.ParseInt(v, 10, 64)
	return n
}

// SetSecret installs the callback secret Rails handed over. A version lower
// than the one held is refused, so a replayed old command cannot restore an
// obsolete secret.
func (w *Worker) SetSecret(ctx context.Context, secret string, version int64) error {
	if secret == "" {
		return ErrNoSecret
	}
	if version < w.SecretVersion(ctx) {
		return ErrStaleSecret
	}
	if err := w.st.SetMeta(ctx, map[string]string{metaSecret: secret, metaSecretVersion: strconv.FormatInt(version, 10)}); err != nil {
		return err
	}
	w.mu.Lock()
	w.secret = []byte(secret)
	w.attempt = version
	w.mu.Unlock()
	return nil
}

func (w *Worker) HasSecret() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.secret) > 0
}

// State is a content-free word for health output and tests.
func (w *Worker) State() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.state
}

func (w *Worker) setState(s string) {
	w.mu.Lock()
	w.state = s
	w.mu.Unlock()
}

// Start runs the session and the sender until Stop. With pair, a session
// without a device pairs (pushing QR codes); without, it stays idle while
// the sender drains whatever is queued.
func (w *Worker) Start(pair bool) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.cancel != nil {
		return errors.New("worker already running")
	}
	if len(w.secret) == 0 {
		return ErrNoSecret
	}
	session, err := w.cfg.Factory(w.st)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	w.session, w.cancel, w.ctx, w.done = session, cancel, ctx, make(chan struct{})
	if pair {
		w.state = "pairing"
	} else {
		w.state = "connecting"
	}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); w.runSession(ctx, session, pair) }()
	go func() { defer wg.Done(); w.send(ctx) }()
	done := w.done
	go func() { wg.Wait(); close(done) }()
	return nil
}

func (w *Worker) runSession(ctx context.Context, s provider.Session, pair bool) {
	err := s.Run(ctx, (*sink)(w), pair)
	switch {
	case err == nil, errors.Is(err, context.Canceled):
	case errors.Is(err, provider.ErrNotPaired):
		w.setState("not_paired")
		w.cfg.Log.Info("session", slog.String("state", "not_paired"))
	case errors.Is(err, provider.ErrLoggedOut):
		w.setState("logged_out")
		w.cfg.Log.Info("session", slog.String("state", "logged_out"))
	default:
		w.setState("failed")
		w.cfg.Log.Error("session", slog.String("reason", "run_failed"))
	}
}

// Stop ends the session and the sender and waits for both.
func (w *Worker) Stop() {
	w.mu.Lock()
	cancel, done := w.cancel, w.done
	w.cancel, w.done, w.ctx = nil, nil, nil
	w.phoneRequest, w.phoneCancel = "", nil
	w.mu.Unlock()
	if cancel == nil {
		return
	}
	cancel()
	<-done
	w.bg.Wait()
}

// PairPhone asks the pairing session for a phone pairing code, for the
// pairing attempt and the phone request (Rails' id for this one ask) the
// command names. It returns at once; the code (or the failure) goes to
// Rails as an event naming the request, like a QR. A newer request
// supersedes this one: its context is cancelled, and whatever it still
// reports is not posted, so a late answer to an old number never reaches
// Rails, whichever order the provider ran them in (Rails also refuses any
// result but its latest request's). The number is passed on and kept
// nowhere: not in the store, not in a log.
//
// Rails sends each command after recording its request, so two commands
// can arrive in either order; seq (Rails' order) decides, not arrival: a
// command whose seq is not above the highest accepted is refused
// (ErrStaleRequest) before anything is cancelled.
func (w *Worker) PairPhone(phone string, attempt int64, request string, seq int64) error {
	if request == "" || seq < 1 {
		return ErrNoRequest
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if attempt != w.attempt {
		return ErrStaleAttempt
	}
	if w.cancel == nil || w.state != "pairing" {
		return ErrNotPairing
	}
	pp, ok := w.session.(provider.PhonePairer)
	if !ok {
		return ErrNotPairing
	}
	if seq <= w.phoneSeq {
		return ErrStaleRequest
	}
	w.phoneSeq = seq
	if w.phoneCancel != nil {
		w.phoneCancel()
	}
	ctx, cancel := context.WithCancel(w.ctx)
	w.phoneRequest, w.phoneCancel = request, cancel
	rs := &requestSink{sink: (*sink)(w), request: request}
	// Added under w.mu while running, so before any Stop can Wait.
	w.bg.Add(1)
	go func() {
		defer w.bg.Done()
		err := pp.RequestPhoneCode(ctx, rs, phone)
		switch {
		case err == nil, errors.Is(err, context.Canceled):
		case errors.Is(err, provider.ErrNotPairing):
			w.cfg.Log.Info("phone_code", slog.String("refused", "not_pairing"))
		default:
			w.cfg.Log.Warn("phone_code", slog.String("reason", "request_failed"))
		}
	}()
	return nil
}

// Close stops the worker, closes the store and releases the lease.
func (w *Worker) Close() {
	w.Stop()
	w.st.Close()
	w.lease.Release()
}

// Unpair stops the worker, logs the linked device out at the network side
// (best effort, bounded), then deletes the store and the connection's
// directory, and only then releases the lease (which lives outside that
// directory and is never deleted), so no other worker can open the
// connection while its files are going.
func (w *Worker) Unpair(ctx context.Context) error {
	w.Stop()
	w.logout(ctx)
	w.st.Close()
	err := store.Remove(filepath.Join(w.dir, StoreFile))
	if err == nil {
		if rmErr := os.RemoveAll(w.dir); rmErr != nil {
			err = rmErr
		}
	}
	if testHookBeforeLeaseRelease != nil {
		testHookBeforeLeaseRelease()
	}
	w.lease.Release()
	return err
}

// logout removes the linked device at the network side: best effort,
// bounded. Only while the session is stopped.
func (w *Worker) logout(ctx context.Context) {
	session, err := w.cfg.Factory(w.st)
	if err != nil {
		return
	}
	lctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := session.Logout(lctx); err != nil {
		w.cfg.Log.Warn("unpair", slog.String("reason", "logout_failed"))
	}
}

// ResetForPairing is start_pairing on a connection that already has a
// store: the worker stops, the old device is logged out (best effort) and
// the store becomes a fresh one (store.ResetSession) holding no secret.
// Chats and messages still waiting for Rails are not lost with the old
// device: they are carried over and sent after the new pairing's
// "connected". The lease stays held throughout.
func (w *Worker) ResetForPairing(ctx context.Context) error {
	w.Stop()
	w.logout(ctx)
	if err := w.st.ResetSession(ctx, carriedOver); err != nil {
		return err
	}
	w.mu.Lock()
	w.secret, w.attempt, w.state = nil, 0, "idle"
	w.refusedID, w.refusals = 0, 0
	w.mu.Unlock()
	return nil
}

// carriedOver: the events a restarted pairing keeps. Status events describe
// the old device and are dropped with it.
func carriedOver(body []byte) bool {
	var ev struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(body, &ev) != nil {
		return false
	}
	return ev.Type == "chat.upsert" || ev.Type == "message.upsert"
}

// revoke runs once, when Rails says the connection is revoked.
func (w *Worker) revoke() {
	w.revoked.Do(func() {
		w.setState("revoked")
		w.cfg.Log.Warn("deliver", slog.String("reason", "connection_revoked"))
		if w.cfg.OnRevoked != nil {
			go w.cfg.OnRevoked(w)
		}
	})
}

func isRevoked(r rails.Reply) bool { return r.Status == 410 && r.Error == "connection_revoked" }

func (w *Worker) poke() {
	select {
	case w.wake <- struct{}{}:
	default:
	}
}

// send delivers the outbox in order, one event per request.
func (w *Worker) send(ctx context.Context) {
	backoff := w.cfg.MinBackoff
	for {
		delivered, err := w.sendOne(ctx)
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			wait(ctx, backoff, nil)
			backoff = min(backoff*2, w.cfg.MaxBackoff)
			continue
		}
		backoff = w.cfg.MinBackoff
		if !delivered {
			wait(ctx, 30*time.Second, w.wake)
		}
	}
}

var errRetry = errors.New("delivery not acknowledged")

// sendOne posts the oldest queued event. It returns delivered=false when
// the outbox is empty.
func (w *Worker) sendOne(ctx context.Context) (bool, error) {
	pending, err := w.st.Pending(ctx, 1)
	if err != nil {
		return false, err
	}
	if len(pending) == 0 {
		return false, nil
	}
	ev := pending[0]
	w.mu.Lock()
	secret, attempt := w.secret, w.attempt
	w.mu.Unlock()

	offStr, known, err := w.st.Meta(ctx, metaSeqOffset)
	if err != nil {
		return false, err
	}
	seq := probeSeq
	if known {
		off, _ := strconv.ParseInt(offStr, 10, 64)
		seq = ev.ID + off
	}
	reply, err := w.cfg.Rails.Post(ctx, w.cfg.Ref, secret, stamp(ev.Body, seq, attempt))
	if err != nil || (reply.Status != 422 && reply.Status != 413) {
		w.refusedID, w.refusals = 0, 0 // the run of refusals is broken
	}
	if err != nil {
		w.cfg.Log.Warn("deliver", slog.String("reason", "rails_unreachable"))
		return false, errRetry
	}
	switch {
	case isRevoked(reply):
		w.revoke()
		return false, errRetry
	case reply.Status == 409 && reply.Error == "sequence_gap" && reply.CommittedSeq != nil:
		// Learn (or relearn) where Rails is: this event becomes the next one.
		off := *reply.CommittedSeq + 1 - ev.ID
		if err := w.st.SetMeta(ctx, map[string]string{metaSeqOffset: strconv.FormatInt(off, 10)}); err != nil {
			return false, err
		}
		return true, nil
	case reply.Status >= 200 && reply.Status < 300 && reply.CommittedSeq != nil && *reply.CommittedSeq >= seq:
		if reply.Skipped != "" {
			w.cfg.Log.Info("deliver", slog.String("skipped", reply.Skipped))
		}
		return true, w.st.Delivered(ctx, ev.ID)
	case reply.Status == 422 || reply.Status == 413:
		if w.refusedID != ev.ID {
			w.refusedID, w.refusals = ev.ID, 0
		}
		w.refusals++
		w.cfg.Log.Warn("deliver", slog.Int("status", reply.Status), slog.String("error", reply.Error))
		if w.refusals >= maxRefusals {
			w.cfg.Log.Error("deliver", slog.String("reason", "dropped_refused_event"))
			return true, w.st.Drop(ctx, ev.ID)
		}
		return false, errRetry
	default:
		// Rails' refusal codes are fixed words (bad_signature,
		// connection_not_accepting, …); they carry no content.
		w.cfg.Log.Warn("deliver", slog.Int("status", reply.Status), slog.String("error", reply.Error))
		return false, errRetry
	}
}

// stamp puts "seq":N (when seq > 0) and "attempt":A first in a JSON object
// body.
func stamp(body []byte, seq, attempt int64) []byte {
	out := make([]byte, 0, len(body)+48)
	out = append(out, '{')
	if seq > 0 {
		out = append(out, `"seq":`...)
		out = strconv.AppendInt(out, seq, 10)
		out = append(out, ',')
	}
	out = append(out, `"attempt":`...)
	out = strconv.AppendInt(out, attempt, 10)
	if len(body) > 2 {
		out = append(out, ',')
	}
	return append(out, body[1:]...)
}

func wait(ctx context.Context, d time.Duration, wake <-chan struct{}) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	case <-wake:
	}
}

// sink is the worker seen as a provider.Sink.
type sink Worker

func (s *sink) w() *Worker { return (*Worker)(s) }

func (s *sink) enqueue(ctx context.Context, bodies ...[]byte) error {
	if err := s.w().st.Enqueue(ctx, bodies...); err != nil {
		return err
	}
	s.w().poke()
	return nil
}

// QR posts a pairing code straight to Rails, retrying until it expires. It
// is never written to the store or a log.
func (s *sink) QR(ctx context.Context, code string, issuedAt, expiresAt time.Time) error {
	raw, err := encodeQR(code, issuedAt, expiresAt)
	if err != nil {
		return err
	}
	return s.postLive(ctx, raw, expiresAt, "qr")
}

// PhoneCode and PhoneCodeFailed on the session's own sink answer no
// request: Rails would refuse them, so they are not sent. Phone results go
// through the requestSink handed to RequestPhoneCode.
func (s *sink) PhoneCode(ctx context.Context, code string, issuedAt, expiresAt time.Time) error {
	return (&requestSink{sink: s}).PhoneCode(ctx, code, issuedAt, expiresAt)
}

func (s *sink) PhoneCodeFailed(ctx context.Context, reason string) error {
	return (&requestSink{sink: s}).PhoneCodeFailed(ctx, reason)
}

// requestSink is the sink one phone request reports through: its results
// name the request, and are dropped once a newer request (or a stop) has
// superseded it.
type requestSink struct {
	*sink
	request string
}

func (r *requestSink) current() bool {
	w := r.w()
	w.mu.Lock()
	defer w.mu.Unlock()
	return r.request != "" && r.request == w.phoneRequest
}

// PhoneCode posts a phone pairing code like a QR: at once, retried until it
// expires, never stored or logged.
func (r *requestSink) PhoneCode(ctx context.Context, code string, issuedAt, expiresAt time.Time) error {
	if !r.current() {
		r.w().cfg.Log.Info("phone_code", slog.String("dropped", "superseded"))
		return nil
	}
	raw, err := encodePhoneCode(code, r.request, issuedAt, expiresAt)
	if err != nil {
		return err
	}
	return r.postLive(ctx, raw, expiresAt, "phone_code")
}

// PhoneCodeFailed tells Rails why no phone code came (a fixed word), retried
// for a minute.
func (r *requestSink) PhoneCodeFailed(ctx context.Context, reason string) error {
	if !r.current() {
		r.w().cfg.Log.Info("phone_code_failed", slog.String("dropped", "superseded"))
		return nil
	}
	raw, err := encodePhoneCodeFailed(reason, r.request)
	if err != nil {
		return err
	}
	return r.postLive(ctx, raw, time.Now().Add(time.Minute), "phone_code_failed")
}

// postLive posts an unqueued pairing event, retrying until the deadline.
// raw is cleared once stamped.
func (s *sink) postLive(ctx context.Context, raw []byte, until time.Time, what string) error {
	w := s.w()
	w.mu.Lock()
	secret, attempt := w.secret, w.attempt
	w.mu.Unlock()
	body := stamp(raw, 0, attempt)
	clear(raw)
	defer clear(body)
	backoff := w.cfg.MinBackoff
	for time.Now().Before(until) {
		reply, err := w.cfg.Rails.Post(ctx, w.cfg.Ref, secret, body)
		if err == nil && isRevoked(reply) {
			w.revoke()
			return nil
		}
		if err == nil && (reply.Status < 300 || reply.Status == 409 || reply.Status == 422) {
			// Accepted, or refused as stale/expired/not pairing: either way
			// resending this code cannot help.
			if reply.Status >= 300 {
				w.cfg.Log.Info(what, slog.String("refused", reply.Error))
			}
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		wait(ctx, backoff, nil)
		backoff = min(backoff*2, w.cfg.MaxBackoff)
	}
	return nil
}

func (s *sink) Connected(ctx context.Context, id provider.Identity) error {
	s.w().setState("connected")
	body, err := encodeStatus("connected", &id)
	if err != nil {
		return err
	}
	// Anything an earlier, restarted pairing left undelivered follows the
	// status that lets Rails accept it.
	if err := s.w().st.EnqueueReleasingCarryover(ctx, body); err != nil {
		return err
	}
	s.w().poke()
	return nil
}

func (s *sink) LoggedOut(ctx context.Context) error {
	s.w().setState("logged_out")
	body, err := encodeStatus("logged_out", nil)
	if err != nil {
		return err
	}
	return s.enqueue(context.WithoutCancel(ctx), body)
}

func (s *sink) Chats(ctx context.Context, chats []provider.Chat) error {
	if len(chats) == 0 {
		return nil
	}
	bodies, err := encodeChats(chats)
	if err != nil {
		return err
	}
	return s.enqueue(ctx, bodies...)
}

func (s *sink) Messages(ctx context.Context, msgs []provider.Message) error {
	if len(msgs) == 0 {
		return nil
	}
	bodies, err := encodeMessages(msgs)
	if err != nil {
		return err
	}
	return s.enqueue(ctx, bodies...)
}
