package command

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"services/comms-connector/internal/sig"
)

// The body and signature Ruby produced (see internal/sig/sig_test.go).
const (
	rubyBody = `{"callback_secret":"c0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeeabcd","callback_secret_version":1,"connection":"svc_42","operation":"start_pairing","command_id":"0123456789abcdef0123456789abcdef","issued_at":1791000000}`
	rubySig  = "f08271d7010a60fda7f1fa9ec6ba3ae7f939066cbe7ddaf725510c3cdabfc1b2"
	cmdID    = "0123456789abcdef0123456789abcdef"
	issued   = int64(1791000000)
)

var key = []byte("test-command-key")

func headers(signature, id string, at int64) http.Header {
	h := http.Header{}
	h.Set(sig.HeaderKeyID, "k1")
	h.Set(sig.HeaderCommandID, id)
	h.Set(sig.HeaderIssuedAt, strconv.FormatInt(at, 10))
	h.Set(sig.HeaderCommand, signature)
	return h
}

// verifier booted bootDelta before the command and asked at now.
func verifier(boot, now int64) *Verifier {
	clock := boot
	v := NewVerifier("k1", key, func() time.Time { return time.Unix(clock, 0) })
	clock = now
	return v
}

func code(err error) string {
	var r *Refused
	if errors.As(err, &r) {
		return r.Code
	}
	return "<" + errors.New("not refused").Error() + ">"
}

func TestRubyCommandVerifies(t *testing.T) {
	v := verifier(issued-100, issued+5)
	cmd, err := v.Verify("svc_42", "start_pairing", headers(rubySig, cmdID, issued), []byte(rubyBody))
	if err != nil {
		t.Fatal(err)
	}
	if cmd.CallbackSecret != "c0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeeabcd" || cmd.CallbackSecretVersion != 1 {
		t.Fatalf("secret not handed over: %+v", cmd.CallbackSecretVersion)
	}
	if strings.Contains(cmd.String(), "c0ffee") {
		t.Fatal("command prints its secret")
	}
	// The same command again is a replay.
	if _, err := v.Verify("svc_42", "start_pairing", headers(rubySig, cmdID, issued), []byte(rubyBody)); code(err) != "replayed_command" {
		t.Fatalf("replay: %v", err)
	}
}

func TestRefusals(t *testing.T) {
	signed := func(body string, ref, op, id string, at int64) (http.Header, []byte) {
		s := sig.SignCommand(key, "k1", ref, op, id, strconv.FormatInt(at, 10), []byte(body))
		return headers(s, id, at), []byte(body)
	}
	cases := []struct {
		name, want string
		run        func() error
	}{
		{"stale", "stale_command", func() error {
			_, err := verifier(issued-100, issued+61).Verify("svc_42", "start_pairing", headers(rubySig, cmdID, issued), []byte(rubyBody))
			return err
		}},
		{"from the future", "stale_command", func() error {
			_, err := verifier(issued-200, issued-61).Verify("svc_42", "start_pairing", headers(rubySig, cmdID, issued), []byte(rubyBody))
			return err
		}},
		{"issued before this process started (replay across a restart)", "stale_command", func() error {
			_, err := verifier(issued+1, issued+2).Verify("svc_42", "start_pairing", headers(rubySig, cmdID, issued), []byte(rubyBody))
			return err
		}},
		{"signed for another connection", "bad_signature", func() error {
			_, err := verifier(issued-1, issued).Verify("svc_43", "start_pairing", headers(rubySig, cmdID, issued), []byte(rubyBody))
			return err
		}},
		{"signed for another operation", "bad_signature", func() error {
			_, err := verifier(issued-1, issued).Verify("svc_42", "unpair", headers(rubySig, cmdID, issued), []byte(rubyBody))
			return err
		}},
		{"tampered body", "bad_signature", func() error {
			_, err := verifier(issued-1, issued).Verify("svc_42", "start_pairing", headers(rubySig, cmdID, issued), []byte(strings.Replace(rubyBody, "c0ffee", "deadbe", 1)))
			return err
		}},
		{"other key", "bad_signature", func() error {
			v := NewVerifier("k1", []byte("another-key"), func() time.Time { return time.Unix(issued, 0) })
			_, err := v.Verify("svc_42", "start_pairing", headers(rubySig, cmdID, issued), []byte(rubyBody))
			return err
		}},
		{"unknown key id", "unknown_key", func() error {
			h := headers(rubySig, cmdID, issued)
			h.Set(sig.HeaderKeyID, "k2")
			_, err := verifier(issued-1, issued).Verify("svc_42", "start_pairing", h, []byte(rubyBody))
			return err
		}},
		{"unsigned", "missing_signature", func() error {
			_, err := verifier(issued-1, issued).Verify("svc_42", "start_pairing", http.Header{}, []byte(rubyBody))
			return err
		}},
		{"body names another connection than it was signed for", "body_mismatch", func() error {
			h, b := signed(strings.Replace(rubyBody, `"connection":"svc_42"`, `"connection":"svc_43"`, 1), "svc_42", "start_pairing", cmdID, issued)
			_, err := verifier(issued-1, issued).Verify("svc_42", "start_pairing", h, b)
			return err
		}},
		{"body names another command id", "body_mismatch", func() error {
			h, b := signed(rubyBody, "svc_42", "start_pairing", "ffffffffffffffffffffffffffffffff", issued)
			_, err := verifier(issued-1, issued).Verify("svc_42", "start_pairing", h, b)
			return err
		}},
		{"body names another time", "body_mismatch", func() error {
			h, b := signed(rubyBody, "svc_42", "start_pairing", cmdID, issued+1)
			_, err := verifier(issued-1, issued).Verify("svc_42", "start_pairing", h, b)
			return err
		}},
		{"not json", "bad_json", func() error {
			h, b := signed("not json", "svc_42", "unpair", cmdID, issued)
			_, err := verifier(issued-1, issued).Verify("svc_42", "unpair", h, b)
			return err
		}},
		{"bad command id", "bad_command_id", func() error {
			_, err := verifier(issued-1, issued).Verify("svc_42", "start_pairing", headers(rubySig, "XYZ", issued), []byte(rubyBody))
			return err
		}},
	}
	for _, c := range cases {
		if got := code(c.run()); got != c.want {
			t.Errorf("%s: got %s, want %s", c.name, got, c.want)
		}
	}
}

// A refused command must not burn its id: otherwise a forgery naming a real
// id could block the real command.
func TestRefusalDoesNotConsumeID(t *testing.T) {
	v := verifier(issued-1, issued)
	if _, err := v.Verify("svc_42", "start_pairing", headers(strings.Repeat("0", 64), cmdID, issued), []byte(rubyBody)); code(err) != "bad_signature" {
		t.Fatal(err)
	}
	if _, err := v.Verify("svc_42", "start_pairing", headers(rubySig, cmdID, issued), []byte(rubyBody)); err != nil {
		t.Fatalf("real command refused after a forgery with its id: %v", err)
	}
}

// pair_phone carries the number, the attempt and the phone request id;
// String shows none of them, and the attempt must be a positive JSON
// integer.
func TestPairPhoneFields(t *testing.T) {
	sign := func(body string) (string, []byte) {
		return sig.SignCommand(key, "k1", "svc_42", "pair_phone", cmdID, strconv.FormatInt(issued, 10), []byte(body)), []byte(body)
	}
	body := func(attempt string) string {
		return `{"phone_number":"+447700900123","request_id":"0123456789abcdef","request_seq":7,"attempt":` + attempt + `,"connection":"svc_42","operation":"pair_phone","command_id":"` + cmdID + `","issued_at":1791000000}`
	}
	s, raw := sign(body("4"))
	cmd, err := verifier(issued-100, issued+5).Verify("svc_42", "pair_phone", headers(s, cmdID, issued), raw)
	if err != nil || cmd.PhoneNumber != "+447700900123" || cmd.Attempt != 4 || cmd.PhoneRequest != "0123456789abcdef" || cmd.PhoneRequestSeq != 7 {
		t.Fatalf("%+v %v", cmd.Attempt, err)
	}
	if strings.Contains(cmd.String(), "7700") {
		t.Fatal("command prints the phone number")
	}
	for _, bad := range []string{`"4"`, `0`, `-1`, `1.5`, `null`, `true`} {
		s, raw := sign(body(bad))
		if _, err := verifier(issued-100, issued+5).Verify("svc_42", "pair_phone", headers(s, cmdID, issued), raw); code(err) != "bad_attempt" {
			t.Errorf("attempt %s: %v", bad, err)
		}
	}
}
