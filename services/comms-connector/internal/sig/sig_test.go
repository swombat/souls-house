package sig

import (
	"net/http"
	"testing"
	"time"
)

// Vectors produced by running the Ruby signers themselves:
//
//	bundle exec ruby -ractive_support/all -ropenssl -rjson -rdigest -e '
//	  load "app/lib/comms_signature.rb"; load "app/lib/comms_command_signature.rb"
//	  body = JSON.generate({ callback_secret: ..., callback_secret_version: 1 }
//	    .merge(connection: "svc_42", operation: "start_pairing", command_id: ..., issued_at: 1791000000))
//	  puts CommsCommandSignature.sign(secret: "test-command-key", key_id: "k1", ...)
//	  puts CommsSignature.headers_for(secret: ..., now: Time.at(1791000000), nonce: ...)'
//
// The command body is exactly what CommsConnector.command sends.
const (
	rubyCommandBody = `{"callback_secret":"c0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeeabcd","callback_secret_version":1,"connection":"svc_42","operation":"start_pairing","command_id":"0123456789abcdef0123456789abcdef","issued_at":1791000000}`
	rubyCommandSig  = "f08271d7010a60fda7f1fa9ec6ba3ae7f939066cbe7ddaf725510c3cdabfc1b2"

	rubyEventBody   = `{"type":"pairing.qr","code":"2@abc,def","issued_at":"2026-10-13T08:00:00Z","expires_at":"2026-10-13T08:00:20Z"}`
	rubyEventSecret = "5ec2e75ec2e75ec2e75ec2e75ec2e75ec2e75ec2e75ec2e75ec2e75ec2e7abcd"
	rubyEventSig    = "61f777aec45d0eb61a81d3ae876dd94501e9baeda38cc4edef564d9446f57af8"
)

func TestCommandSignatureMatchesRuby(t *testing.T) {
	key := []byte("test-command-key")
	got := SignCommand(key, "k1", "svc_42", "start_pairing", "0123456789abcdef0123456789abcdef", "1791000000", []byte(rubyCommandBody))
	if got != rubyCommandSig {
		t.Fatalf("Go command signature %s, Ruby %s", got, rubyCommandSig)
	}
	if !VerifyCommand(key, rubyCommandSig, "k1", "svc_42", "start_pairing", "0123456789abcdef0123456789abcdef", "1791000000", []byte(rubyCommandBody)) {
		t.Fatal("Ruby's signature does not verify")
	}
	// Every signed part matters.
	for name, ok := range map[string]bool{
		"key id":     VerifyCommand(key, rubyCommandSig, "k2", "svc_42", "start_pairing", "0123456789abcdef0123456789abcdef", "1791000000", []byte(rubyCommandBody)),
		"connection": VerifyCommand(key, rubyCommandSig, "k1", "svc_43", "start_pairing", "0123456789abcdef0123456789abcdef", "1791000000", []byte(rubyCommandBody)),
		"operation":  VerifyCommand(key, rubyCommandSig, "k1", "svc_42", "unpair", "0123456789abcdef0123456789abcdef", "1791000000", []byte(rubyCommandBody)),
		"command id": VerifyCommand(key, rubyCommandSig, "k1", "svc_42", "start_pairing", "0123456789abcdef0123456789abcdee", "1791000000", []byte(rubyCommandBody)),
		"issued at":  VerifyCommand(key, rubyCommandSig, "k1", "svc_42", "start_pairing", "0123456789abcdef0123456789abcdef", "1791000001", []byte(rubyCommandBody)),
		"body":       VerifyCommand(key, rubyCommandSig, "k1", "svc_42", "start_pairing", "0123456789abcdef0123456789abcdef", "1791000000", []byte(rubyCommandBody+" ")),
		"key":        VerifyCommand([]byte("other-key"), rubyCommandSig, "k1", "svc_42", "start_pairing", "0123456789abcdef0123456789abcdef", "1791000000", []byte(rubyCommandBody)),
	} {
		if ok {
			t.Errorf("changed %s still verifies", name)
		}
	}
}

func TestEventSignatureMatchesRuby(t *testing.T) {
	got := SignEvent([]byte(rubyEventSecret), "svc_42", "post", "/internal/comms/connections/svc_42/events", "1791000000", "fedcba9876543210fedcba9876543210", []byte(rubyEventBody))
	if got != rubyEventSig {
		t.Fatalf("Go event signature %s, Ruby %s", got, rubyEventSig)
	}
}

func TestSetEventHeaders(t *testing.T) {
	h := http.Header{}
	path := "/internal/comms/connections/svc_42/events"
	if err := SetEventHeaders(h, []byte(rubyEventSecret), "svc_42", "POST", path, []byte(rubyEventBody), time.Unix(1791000000, 0)); err != nil {
		t.Fatal(err)
	}
	if h.Get(HeaderConnection) != "svc_42" || h.Get(HeaderTimestamp) != "1791000000" || len(h.Get(HeaderNonce)) != 32 {
		t.Fatalf("headers %v", h)
	}
	want := SignEvent([]byte(rubyEventSecret), "svc_42", "POST", path, "1791000000", h.Get(HeaderNonce), []byte(rubyEventBody))
	if h.Get(HeaderSignature) != want {
		t.Fatal("header signature does not cover the nonce it sends")
	}
	h2 := http.Header{}
	SetEventHeaders(h2, []byte(rubyEventSecret), "svc_42", "POST", path, []byte(rubyEventBody), time.Unix(1791000000, 0))
	if h2.Get(HeaderNonce) == h.Get(HeaderNonce) {
		t.Fatal("nonce reused")
	}
}
