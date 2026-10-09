// Package keys holds the KEK/DEK envelope and the SQLCipher subkey derivation.
//
// KEK: 32 raw bytes from COMMS_KEK (standard base64).
// DEK: 32 random bytes per (connection_ref, key_generation), wrapped with
// XChaCha20-Poly1305 under the KEK, fresh 24-byte nonce per wrap,
// AAD = lp("comms-dek-v1") || lp(connection_ref) || lp(be64(key_generation)),
// where lp(x) = be32(len(x)) || x.
// SQLCipher key: HKDF-SHA256(DEK, salt = none, info = "comms-sqlcipher-v1"), 32 bytes.
package keys

import (
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/crypto/chacha20poly1305"

	"services/comms-connector/internal/ids"
)

const (
	KeySize       = 32
	aadLabel      = "comms-dek-v1"
	sqlcipherInfo = "comms-sqlcipher-v1"
	logIDInfo     = "comms-log-id-v1"
	// wrapped file: magic(4) || nonce(24) || ciphertext(32+16)
	wrapMagic   = "CDK1"
	wrappedSize = len(wrapMagic) + chacha20poly1305.NonceSizeX + KeySize + chacha20poly1305.Overhead
)

// Fixed, content-free errors. None of them carries key material or input.
var (
	ErrKEK        = errors.New("COMMS_KEK missing or invalid")
	ErrUnwrap     = errors.New("unwrap DEK failed")
	ErrBadRef     = errors.New("invalid connection ref")
	ErrBadGen     = errors.New("invalid key generation")
	ErrDEKMissing = errors.New("wrapped DEK not found")
	ErrDEKExists  = errors.New("wrapped DEK already exists")
	ErrDEKIO      = errors.New("wrapped DEK io failed")
)

// ParseKEK decodes a standard-base64 KEK and requires exactly 32 bytes.
func ParseKEK(b64 string) ([]byte, error) {
	if b64 == "" {
		return nil, ErrKEK
	}
	k, err := base64.StdEncoding.Strict().DecodeString(b64)
	// The decoder skips '\r' and '\n'; the re-encode check refuses them and
	// any other non-canonical form.
	if err != nil || len(k) != KeySize || base64.StdEncoding.EncodeToString(k) != b64 {
		return nil, ErrKEK
	}
	return k, nil
}

func lp(b []byte, out []byte) []byte {
	out = binary.BigEndian.AppendUint32(out, uint32(len(b)))
	return append(out, b...)
}

// AAD returns the unambiguous associated data for a wrapped DEK.
func AAD(ref string, gen uint64) []byte {
	var g [8]byte
	binary.BigEndian.PutUint64(g[:], gen)
	out := lp([]byte(aadLabel), nil)
	out = lp([]byte(ref), out)
	return lp(g[:], out)
}

func checkArgs(kek []byte, ref string, gen uint64) error {
	if len(kek) != KeySize {
		return ErrKEK
	}
	if !ids.ValidConnectionRef(ref) {
		return ErrBadRef
	}
	if gen == 0 {
		return ErrBadGen
	}
	return nil
}

// Wrap seals dek under kek for (ref, gen) with a fresh random nonce.
func Wrap(kek, dek []byte, ref string, gen uint64) ([]byte, error) {
	if err := checkArgs(kek, ref, gen); err != nil {
		return nil, err
	}
	if len(dek) != KeySize {
		return nil, errors.New("invalid DEK length")
	}
	aead, err := chacha20poly1305.NewX(kek)
	if err != nil {
		return nil, ErrKEK
	}
	out := make([]byte, len(wrapMagic)+chacha20poly1305.NonceSizeX, wrappedSize)
	copy(out, wrapMagic)
	nonce := out[len(wrapMagic):]
	if _, err := rand.Read(nonce); err != nil {
		return nil, errors.New("random source failed")
	}
	return aead.Seal(out, nonce, dek, AAD(ref, gen)), nil
}

// Unwrap opens a wrapped DEK. Any mismatch (ref, gen, KEK, tampering) is ErrUnwrap.
func Unwrap(kek, wrapped []byte, ref string, gen uint64) ([]byte, error) {
	if err := checkArgs(kek, ref, gen); err != nil {
		return nil, err
	}
	if len(wrapped) != wrappedSize || string(wrapped[:len(wrapMagic)]) != wrapMagic {
		return nil, ErrUnwrap
	}
	aead, err := chacha20poly1305.NewX(kek)
	if err != nil {
		return nil, ErrKEK
	}
	nonce := wrapped[len(wrapMagic) : len(wrapMagic)+chacha20poly1305.NonceSizeX]
	ct := wrapped[len(wrapMagic)+chacha20poly1305.NonceSizeX:]
	dek, err := aead.Open(nil, nonce, ct, AAD(ref, gen))
	if err != nil {
		return nil, ErrUnwrap
	}
	return dek, nil
}

// NewDEK returns 32 fresh random bytes.
func NewDEK() ([]byte, error) {
	k := make([]byte, KeySize)
	if _, err := rand.Read(k); err != nil {
		return nil, errors.New("random source failed")
	}
	return k, nil
}

// SQLCipherKey derives the database key from a DEK.
func SQLCipherKey(dek []byte) ([]byte, error) {
	if len(dek) != KeySize {
		return nil, errors.New("invalid DEK length")
	}
	return hkdf.Key(sha256.New, dek, nil, sqlcipherInfo, KeySize)
}

// LogIDKey derives the key used to hash connection refs for stdout logs.
func LogIDKey(kek []byte) ([]byte, error) {
	if len(kek) != KeySize {
		return nil, ErrKEK
	}
	return hkdf.Key(sha256.New, kek, nil, logIDInfo, KeySize)
}

// LogID is the opaque stand-in for a connection ref in stdout logs: the
// first 16 hex characters of HMAC-SHA256(LogIDKey(kek), ref).
func LogID(kek []byte, ref string) (string, error) {
	k, err := LogIDKey(kek)
	if err != nil {
		return "", err
	}
	m := hmac.New(sha256.New, k)
	m.Write([]byte(ref))
	return hex.EncodeToString(m.Sum(nil))[:16], nil
}

// ConnDir returns <dataDir>/<ref> after validating ref.
func ConnDir(dataDir, ref string) (string, error) {
	if !ids.ValidConnectionRef(ref) {
		return "", ErrBadRef
	}
	return filepath.Join(dataDir, ref), nil
}

// WrappedPath returns <dataDir>/<ref>/dek-<gen>.wrapped.
func WrappedPath(dataDir, ref string, gen uint64) (string, error) {
	dir, err := ConnDir(dataDir, ref)
	if err != nil {
		return "", err
	}
	if gen == 0 {
		return "", ErrBadGen
	}
	return filepath.Join(dir, fmt.Sprintf("dek-%d.wrapped", gen)), nil
}

// CreateDEK generates, wraps and durably stores a new DEK for (ref, gen).
// It refuses to overwrite an existing wrapped DEK. The connection directory
// must already exist (the caller creates it and takes the lease first).
func CreateDEK(dataDir string, kek []byte, ref string, gen uint64) ([]byte, error) {
	p, err := WrappedPath(dataDir, ref, gen)
	if err != nil {
		return nil, err
	}
	dek, err := NewDEK()
	if err != nil {
		return nil, err
	}
	w, err := Wrap(kek, dek, ref, gen)
	if err != nil {
		return nil, err
	}
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			return nil, ErrDEKExists
		}
		return nil, ErrDEKIO
	}
	if _, err := f.Write(w); err != nil {
		f.Close()
		os.Remove(p)
		return nil, ErrDEKIO
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(p)
		return nil, ErrDEKIO
	}
	if err := f.Close(); err != nil {
		return nil, ErrDEKIO
	}
	if d, err := os.Open(filepath.Dir(p)); err == nil {
		_ = d.Sync()
		d.Close()
	}
	return dek, nil
}

// LoadDEK reads and unwraps the stored DEK for (ref, gen).
func LoadDEK(dataDir string, kek []byte, ref string, gen uint64) ([]byte, error) {
	p, err := WrappedPath(dataDir, ref, gen)
	if err != nil {
		return nil, err
	}
	w, err := os.ReadFile(p)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, ErrDEKMissing
		}
		return nil, ErrDEKIO
	}
	return Unwrap(kek, w, ref, gen)
}
