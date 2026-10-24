package whatsapp

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"go.mau.fi/whatsmeow"

	"services/comms-connector/internal/provider"
)

const testPhone = "447700900123"

// pairingRig is a Session whose pairing connection is a channel the test
// drives (as whatsmeow's QR channel), and whose PairPhone is a fake that
// records when it was called.
type pairingRig struct {
	s      *Session
	sink   *recSink
	qr     chan whatsmeow.QRChannelItem
	calls  atomic.Int32
	phones chan string
	loop   chan error
}

func newPairingRig(t *testing.T, pairPhone func(context.Context, string) (string, error)) *pairingRig {
	t.Helper()
	st := openStore(t, filepath.Join(t.TempDir(), "store.db"), newKey())
	t.Cleanup(func() { st.Close() })
	r := &pairingRig{s: mustSession(t, st), sink: &recSink{}, qr: make(chan whatsmeow.QRChannelItem),
		phones: make(chan string, 4), loop: make(chan error, 1)}
	r.s.pairPhone = func(ctx context.Context, phone string) (string, error) {
		r.calls.Add(1)
		r.phones <- phone
		return pairPhone(ctx, phone)
	}
	go func() { r.loop <- r.s.pairLoop(context.Background(), r.qr, r.sink) }()
	return r
}

func (r *pairingRig) request(ctx context.Context) chan error {
	done := make(chan error, 1)
	go func() { done <- r.s.RequestPhoneCode(ctx, r.sink, testPhone) }()
	return done
}

func (r *pairingRig) code(timeout time.Duration) whatsmeow.QRChannelItem {
	return whatsmeow.QRChannelItem{Event: whatsmeow.QRChannelEventCode, Code: "2@qr", Timeout: timeout}
}

// whatsmeow's PairPhone only works on a pairing connection that has already
// produced its first QR. A request that arrives first (the owner typed the
// number before WhatsApp answered) waits for it rather than failing.
func TestPhoneCodeWaitsForTheFirstQR(t *testing.T) {
	r := newPairingRig(t, func(context.Context, string) (string, error) { return "ABCD-EFGH", nil })
	done := r.request(context.Background())
	time.Sleep(150 * time.Millisecond)
	if n := r.calls.Load(); n != 0 {
		t.Fatalf("PairPhone called %d times before the first QR", n)
	}
	before := time.Now()
	r.qr <- r.code(60 * time.Second)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if got := <-r.phones; got != testPhone {
		t.Fatalf("PairPhone got %q", got)
	}
	r.sink.mu.Lock()
	defer r.sink.mu.Unlock()
	if len(r.sink.phoneCodes) != 1 || r.sink.phoneCodes[0].code != "ABCD-EFGH" {
		t.Fatalf("codes %+v", r.sink.phoneCodes)
	}
	// The code lives as long as the pairing connection: 160 s from its first QR.
	got := r.sink.phoneCodes[0].expiresAt.Sub(before)
	if got < PairingWindow-time.Second || got > PairingWindow+time.Second {
		t.Fatalf("code expires %v after the first QR, want about %v", got, PairingWindow)
	}
	if len(r.sink.qrs) != 1 {
		t.Fatalf("the QR still goes to Rails as usual: %v", r.sink.qrs)
	}
}

// WhatsApp's errors become fixed words: its error text can carry the
// number (it echoes the request node), and nothing else may leave.
func TestPhoneCodeFailuresAreFixedWords(t *testing.T) {
	for _, tc := range []struct {
		err  error
		want string
	}{
		{whatsmeow.ErrIQRateOverLimit, provider.PhoneCodeRateLimited},
		{whatsmeow.ErrIQBadRequest, provider.PhoneCodeInvalid},
		{whatsmeow.ErrPhoneNumberIsNotInternational, provider.PhoneCodeInvalid},
		{fmt.Errorf("unexpected node with jid %s@s.whatsapp.net", testPhone), provider.PhoneCodeFailed},
	} {
		r := newPairingRig(t, func(context.Context, string) (string, error) { return "", tc.err })
		done := r.request(context.Background())
		r.qr <- r.code(60 * time.Second)
		if err := <-done; err != nil {
			t.Fatal(err)
		}
		r.sink.mu.Lock()
		if len(r.sink.phoneFailed) != 1 || r.sink.phoneFailed[0] != tc.want || len(r.sink.phoneCodes) != 0 {
			t.Errorf("%v: failed %v codes %v", tc.err, r.sink.phoneFailed, r.sink.phoneCodes)
		}
		r.sink.mu.Unlock()
	}
}

// The codes run out with a phone code issued and nothing entered: Rails
// hears that the code expired, so the owner is offered a restart at once.
func TestPhoneCodeExpiresWithThePairingConnection(t *testing.T) {
	r := newPairingRig(t, func(context.Context, string) (string, error) { return "ABCD-EFGH", nil })
	done := r.request(context.Background())
	r.qr <- r.code(60 * time.Second)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	r.qr <- whatsmeow.QRChannelTimeout
	if err := <-r.loop; !errors.Is(err, ErrPairingEnded) {
		t.Fatalf("pairLoop: %v", err)
	}
	r.sink.mu.Lock()
	failed := append([]string(nil), r.sink.phoneFailed...)
	r.sink.mu.Unlock()
	if len(failed) != 1 || failed[0] != provider.PhoneCodeExpired {
		t.Fatalf("failed %v", failed)
	}
	// And a request after the end is refused without calling WhatsApp.
	if err := r.s.RequestPhoneCode(context.Background(), r.sink, testPhone); !errors.Is(err, provider.ErrNotPairing) || r.calls.Load() != 1 {
		t.Fatalf("after the end: %v, %d calls", err, r.calls.Load())
	}
}

// A pairing that ends before its first QR (no connection) refuses the
// request; without a phone code issued, nothing is said about expiry.
func TestPhoneCodeRequestRefusedWhenPairingEndsFirst(t *testing.T) {
	r := newPairingRig(t, func(context.Context, string) (string, error) { return "ABCD-EFGH", nil })
	done := r.request(context.Background())
	close(r.qr)
	if err := <-done; !errors.Is(err, provider.ErrNotPairing) {
		t.Fatalf("got %v", err)
	}
	<-r.loop
	r.sink.mu.Lock()
	defer r.sink.mu.Unlock()
	if r.calls.Load() != 0 || len(r.sink.phoneFailed) != 0 || len(r.sink.phoneCodes) != 0 {
		t.Fatalf("calls %d failed %v codes %v", r.calls.Load(), r.sink.phoneFailed, r.sink.phoneCodes)
	}
}

// The connection never comes up: the owner is told, rather than waiting.
func TestPhoneCodeNotReady(t *testing.T) {
	old := ReadyTimeout
	ReadyTimeout = 100 * time.Millisecond
	t.Cleanup(func() { ReadyTimeout = old })
	r := newPairingRig(t, func(context.Context, string) (string, error) { return "ABCD-EFGH", nil })
	if err := <-r.request(context.Background()); err != nil {
		t.Fatal(err)
	}
	r.sink.mu.Lock()
	defer r.sink.mu.Unlock()
	if r.calls.Load() != 0 || len(r.sink.phoneFailed) != 1 || r.sink.phoneFailed[0] != provider.PhoneCodeNotReady {
		t.Fatalf("calls %d failed %v", r.calls.Load(), r.sink.phoneFailed)
	}
	close(r.qr)
}

// The expiry belongs to the request whose code expired: it goes through
// that request's sink (which names the request to Rails, and drops it if a
// newer request has superseded it), not the session's own sink, whose
// phone results name no request.
func TestPhoneCodeExpiryGoesToTheRequestThatGotTheCode(t *testing.T) {
	r := newPairingRig(t, func(context.Context, string) (string, error) { return "ABCD-EFGH", nil })
	requestSink := &recSink{}
	done := make(chan error, 1)
	go func() { done <- r.s.RequestPhoneCode(context.Background(), requestSink, testPhone) }()
	r.qr <- r.code(60 * time.Second)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	r.qr <- whatsmeow.QRChannelTimeout
	if err := <-r.loop; !errors.Is(err, ErrPairingEnded) {
		t.Fatalf("pairLoop: %v", err)
	}
	requestSink.mu.Lock()
	reqFailed := append([]string(nil), requestSink.phoneFailed...)
	requestSink.mu.Unlock()
	r.sink.mu.Lock()
	runFailed := append([]string(nil), r.sink.phoneFailed...)
	r.sink.mu.Unlock()
	if len(reqFailed) != 1 || reqFailed[0] != provider.PhoneCodeExpired || len(runFailed) != 0 {
		t.Fatalf("request sink got %v, session sink got %v", reqFailed, runFailed)
	}
}
