// Package sig is the connector's half of the two signatures Rails uses
// with it. Both are HMAC-SHA256, lowercase hex, and must match the Ruby
// byte for byte (sig_test.go pins vectors produced by the Ruby signers).
//
// Commands, Rails → connector (app/lib/comms_command_signature.rb), signed
// with the connector-wide COMMS_COMMAND_KEY:
//
//	v1 LF key-id LF connection LF operation LF command-id LF issued-at LF hex(sha256(body))
//
// Events, connector → Rails (app/lib/comms_signature.rb), signed with the
// connection's own callback secret:
//
//	connection LF METHOD LF path LF unix-seconds LF nonce LF raw-body
package sig

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Command headers, as CommsCommandSignature::HEADERS.
const (
	HeaderKeyID     = "X-Comms-Key-Id"
	HeaderCommandID = "X-Comms-Command-Id"
	HeaderIssuedAt  = "X-Comms-Issued-At"
	HeaderCommand   = "X-Comms-Command-Signature"
)

// Event headers, as CommsSignature::HEADERS.
const (
	HeaderConnection = "X-Comms-Connection"
	HeaderTimestamp  = "X-Comms-Timestamp"
	HeaderNonce      = "X-Comms-Nonce"
	HeaderSignature  = "X-Comms-Signature"
)

func CommandSigningString(keyID, connection, operation, commandID, issuedAt string, body []byte) string {
	sum := sha256.Sum256(body)
	return strings.Join([]string{"v1", keyID, connection, operation, commandID, issuedAt, hex.EncodeToString(sum[:])}, "\n")
}

func SignCommand(key []byte, keyID, connection, operation, commandID, issuedAt string, body []byte) string {
	return mac(key, CommandSigningString(keyID, connection, operation, commandID, issuedAt, body))
}

// VerifyCommand compares in constant time.
func VerifyCommand(key []byte, signature, keyID, connection, operation, commandID, issuedAt string, body []byte) bool {
	want := SignCommand(key, keyID, connection, operation, commandID, issuedAt, body)
	return hmac.Equal([]byte(signature), []byte(want))
}

func EventSigningString(connection, method, path, timestamp, nonce string, body []byte) string {
	return strings.Join([]string{connection, strings.ToUpper(method), path, timestamp, nonce, string(body)}, "\n")
}

func SignEvent(secret []byte, connection, method, path, timestamp, nonce string, body []byte) string {
	return mac(secret, EventSigningString(connection, method, path, timestamp, nonce, body))
}

// SetEventHeaders signs an outgoing event request with a fresh nonce.
func SetEventHeaders(h http.Header, secret []byte, connection, method, path string, body []byte, now time.Time) error {
	nonce, err := Nonce()
	if err != nil {
		return err
	}
	ts := strconv.FormatInt(now.Unix(), 10)
	h.Set(HeaderConnection, connection)
	h.Set(HeaderTimestamp, ts)
	h.Set(HeaderNonce, nonce)
	h.Set(HeaderSignature, SignEvent(secret, connection, method, path, ts, nonce, body))
	return nil
}

// Nonce is 16 random bytes in lowercase hex, as SecureRandom.hex(16).
func Nonce() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func mac(key []byte, s string) string {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(s))
	return hex.EncodeToString(m.Sum(nil))
}
