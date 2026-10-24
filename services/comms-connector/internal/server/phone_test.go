package server

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"services/comms-connector/internal/keys"
	"services/comms-connector/internal/worker"
)

const (
	phoneDigits  = "447700900456"
	phoneRequest = "0123456789abcdef"
)

func phoneEvents(r *rig) []map[string]any {
	_, _, events, _ := r.rails.snapshot(ref)
	var out []map[string]any
	for _, ev := range events {
		if t, _ := ev["type"].(string); strings.HasPrefix(t, "pairing.phone_code") {
			out = append(out, ev)
		}
	}
	return out
}

// pair_phone on a pairing connection: the phone code reaches Rails signed,
// stamped with the attempt, unsequenced (like a QR); the number is in no
// log line, nowhere in the store file and in no body sent to Rails.
func TestPairPhoneDeliversTheCodeForTheAttempt(t *testing.T) {
	r := newRig(t)
	r.syn.QRCodes = 1000 // stays pairing for the test's length
	r.syn.QRInterval = 50 * time.Millisecond
	r.syn.PhoneCode = "WXYZ-2345"
	r.rails.expectAttempt(ref, secret, 3)
	m := r.manager()
	if err := m.StartPairing(context.Background(), ref, secret, 3); err != nil {
		t.Fatal(err)
	}
	if err := m.PairPhone(context.Background(), ref, phoneDigits, 2, phoneRequest, 1); !errors.Is(err, worker.ErrStaleAttempt) {
		t.Fatalf("an older attempt's pair_phone: %v", err)
	}
	if err := m.PairPhone(context.Background(), ref, phoneDigits, 3, phoneRequest, 1); err != nil {
		t.Fatal(err)
	}
	eventually(t, "phone code at Rails", func() bool { return len(phoneEvents(r)) == 1 })
	ev := phoneEvents(r)[0]
	if ev["type"] != "pairing.phone_code" || ev["code"] != "WXYZ-2345" || ev["attempt"].(interface{ String() string }).String() != "3" ||
		ev["request_id"] != phoneRequest {
		t.Fatalf("event %v", ev)
	}
	if _, sequenced := ev["seq"]; sequenced {
		t.Fatal("a phone code went through the outbox")
	}
	issued, _ := time.Parse(time.RFC3339Nano, ev["issued_at"].(string))
	expires, _ := time.Parse(time.RFC3339Nano, ev["expires_at"].(string))
	if !expires.After(issued) {
		t.Fatalf("issued %v expires %v", issued, expires)
	}
	if r.syn.LastPhone() != phoneDigits || r.syn.PhoneCodes() != 1 {
		t.Fatalf("provider got %q, %d codes", r.syn.LastPhone(), r.syn.PhoneCodes())
	}
	m.Close()
	dir, _ := keys.ConnDir(r.data, ref)
	raw, _ := os.ReadFile(filepath.Join(dir, worker.StoreFile))
	for where, text := range map[string]string{"logs": r.logs.String(), "store": string(raw), "rails": strings.Join(r.rails.raw, "\n")} {
		if strings.Contains(text, phoneDigits) {
			t.Errorf("phone number in %s", where)
		}
	}
	if strings.Contains(r.logs.String(), "WXYZ") {
		t.Error("phone code logged")
	}
}

// A provider failure reaches Rails as its fixed word.
func TestPairPhoneFailureReachesRails(t *testing.T) {
	r := newRig(t)
	r.syn.QRCodes = 1000
	r.syn.QRInterval = 50 * time.Millisecond
	r.syn.PhoneFailure = "rate_limited"
	r.rails.expect(ref, secret)
	m := r.manager()
	if err := m.StartPairing(context.Background(), ref, secret, 1); err != nil {
		t.Fatal(err)
	}
	if err := m.PairPhone(context.Background(), ref, phoneDigits, 1, phoneRequest, 1); err != nil {
		t.Fatal(err)
	}
	eventually(t, "failure at Rails", func() bool { return len(phoneEvents(r)) == 1 })
	if ev := phoneEvents(r)[0]; ev["type"] != "pairing.phone_code_failed" || ev["reason"] != "rate_limited" || ev["request_id"] != phoneRequest {
		t.Fatalf("event %v", ev)
	}
}

// Not pairing: unknown connections, and linked ones, are refused.
func TestPairPhoneRefusedWhenNotPairing(t *testing.T) {
	r := newRig(t)
	r.rails.expect(ref, secret)
	m := r.manager()
	if err := m.PairPhone(context.Background(), ref, phoneDigits, 1, phoneRequest, 1); !errors.Is(err, worker.ErrNotPairing) {
		t.Fatalf("unknown connection: %v", err)
	}
	if err := m.StartPairing(context.Background(), ref, secret, 1); err != nil {
		t.Fatal(err)
	}
	r.wantAllDelivered(15)
	eventually(t, "connected", func() bool { return m.State(ref) == "connected" })
	if err := m.PairPhone(context.Background(), ref, phoneDigits, 1, phoneRequest, 1); !errors.Is(err, worker.ErrNotPairing) {
		t.Fatalf("linked connection: %v", err)
	}
	if r.syn.PhoneCodes() != 0 {
		t.Fatal("a code was asked for")
	}
}

// Restarting pairing (or unpairing) while a phone code request waits for
// the first QR stops it cleanly: Stop waits for the request (-race).
func TestPairPhoneRequestEndsWithTheSession(t *testing.T) {
	r := newRig(t)
	r.syn.QRCodes = 1000
	r.syn.QRInterval = 50 * time.Millisecond
	r.rails.expect(ref, secret)
	r.rails.setDown(true) // the first QR never lands, so the request is still waiting
	m := r.manager()
	if err := m.StartPairing(context.Background(), ref, secret, 1); err != nil {
		t.Fatal(err)
	}
	if err := m.PairPhone(context.Background(), ref, phoneDigits, 1, phoneRequest, 1); err != nil {
		t.Fatal(err)
	}
	r.rails.expectAttempt(ref, secret, 2)
	if err := m.StartPairing(context.Background(), ref, secret, 2); err != nil {
		t.Fatal(err)
	}
	if err := m.Unpair(context.Background(), ref); err != nil {
		t.Fatal(err)
	}
}
