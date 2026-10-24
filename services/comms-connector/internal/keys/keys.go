// Package keys derives each connection's SQLCipher key and its log id from
// the connector-wide COMMS_STORE_KEY (proposal 2026-10-09 §2):
//
//	store key  = HKDF-SHA256(COMMS_STORE_KEY, salt = none, info = "comms-sqlcipher-v1" || 0x00 || ref), 32 bytes
//	log id key = HKDF-SHA256(COMMS_STORE_KEY, salt = none, info = "comms-log-id-v1"), 32 bytes
//
// There is no envelope and no per-connection key file: losing the volume
// costs a re-pair, and COMMS_STORE_KEY is an accessory secret like any other.
package keys

import (
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"path/filepath"

	"services/comms-connector/internal/ids"
)

const (
	KeySize       = 32
	sqlcipherInfo = "comms-sqlcipher-v1"
	logIDInfo     = "comms-log-id-v1"
)

// Fixed, content-free errors. None carries key material or input.
var (
	ErrStoreKey = errors.New("COMMS_STORE_KEY missing or invalid")
	ErrBadRef   = errors.New("invalid connection ref")
)

// ParseStoreKey decodes canonical standard base64 and requires 32 bytes.
func ParseStoreKey(b64 string) ([]byte, error) {
	if b64 == "" {
		return nil, ErrStoreKey
	}
	k, err := base64.StdEncoding.Strict().DecodeString(b64)
	// The decoder skips '\r' and '\n'; the re-encode check refuses them and
	// any other non-canonical form.
	if err != nil || len(k) != KeySize || base64.StdEncoding.EncodeToString(k) != b64 {
		return nil, ErrStoreKey
	}
	return k, nil
}

// StoreKey derives the SQLCipher key of one connection's store.
func StoreKey(master []byte, ref string) ([]byte, error) {
	if len(master) != KeySize {
		return nil, ErrStoreKey
	}
	if !ids.ValidConnectionRef(ref) {
		return nil, ErrBadRef
	}
	return hkdf.Key(sha256.New, master, nil, sqlcipherInfo+"\x00"+ref, KeySize)
}

// LogID is the opaque stand-in for a connection ref in stdout logs: the
// first 16 hex characters of HMAC-SHA256(HKDF(master, "comms-log-id-v1"), ref).
func LogID(master []byte, ref string) (string, error) {
	if len(master) != KeySize {
		return "", ErrStoreKey
	}
	k, err := hkdf.Key(sha256.New, master, nil, logIDInfo, KeySize)
	if err != nil {
		return "", ErrStoreKey
	}
	m := hmac.New(sha256.New, k)
	m.Write([]byte(ref))
	return hex.EncodeToString(m.Sum(nil))[:16], nil
}

// LeaseDir holds every connection's lease file. It is not a valid
// connection ref, so Boot never takes it for a connection.
const LeaseDir = ".leases"

// LeasePath returns <dataDir>/.leases/<ref> after validating ref. It is
// outside ConnDir, which unpair deletes.
func LeasePath(dataDir, ref string) (string, error) {
	if !ids.ValidConnectionRef(ref) {
		return "", ErrBadRef
	}
	return filepath.Join(dataDir, LeaseDir, ref), nil
}

// ConnDir returns <dataDir>/<ref> after validating ref.
func ConnDir(dataDir, ref string) (string, error) {
	if !ids.ValidConnectionRef(ref) {
		return "", ErrBadRef
	}
	return filepath.Join(dataDir, ref), nil
}
