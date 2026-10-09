package keys

import (
	"bytes"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

const refA, refB = "conn-aaaaaaaa", "conn-bbbbbbbb"

func mustKEK(t *testing.T) []byte {
	t.Helper()
	k, err := NewDEK()
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestParseKEK(t *testing.T) {
	good := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	if k, err := ParseKEK(good); err != nil || len(k) != 32 {
		t.Fatalf("good KEK refused")
	}
	for name, v := range map[string]string{
		"missing":   "",
		"short":     base64.StdEncoding.EncodeToString(make([]byte, 31)),
		"long":      base64.StdEncoding.EncodeToString(make([]byte, 33)),
		"not b64":   "!!!!",
		"url b64":   base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0xfb}, 32)),
		"trailing":  good + "\n",
		"hex-ish32": "0123456789abcdef0123456789abcdef",
	} {
		if _, err := ParseKEK(v); !errors.Is(err, ErrKEK) {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestWrapRoundTrip(t *testing.T) {
	kek := mustKEK(t)
	dek := mustKEK(t)
	w, err := Wrap(kek, dek, refA, 1)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Unwrap(kek, w, refA, 1)
	if err != nil || !bytes.Equal(got, dek) {
		t.Fatal("round trip failed")
	}
}

func TestUnwrapBindsConnectionAndGeneration(t *testing.T) {
	kek := mustKEK(t)
	dek := mustKEK(t)
	w, _ := Wrap(kek, dek, refA, 1)
	if _, err := Unwrap(kek, w, refB, 1); !errors.Is(err, ErrUnwrap) {
		t.Error("DEK for A unwrapped as B")
	}
	if _, err := Unwrap(kek, w, refA, 2); !errors.Is(err, ErrUnwrap) {
		t.Error("DEK for generation 1 unwrapped as generation 2")
	}
	if _, err := Unwrap(mustKEK(t), w, refA, 1); !errors.Is(err, ErrUnwrap) {
		t.Error("DEK unwrapped under another KEK")
	}
	// The length prefix makes ("conn-aaaaaaaa1", gen) and ("conn-aaaaaaaa", ...) distinct encodings.
	if bytes.Equal(AAD("conn-aaaaaaaa", 0x31), AAD("conn-aaaaaaaa1", 0)) {
		t.Error("AAD encoding is ambiguous")
	}
}

func TestUnwrapDetectsTampering(t *testing.T) {
	kek := mustKEK(t)
	w, _ := Wrap(kek, mustKEK(t), refA, 1)
	for _, pos := range []int{
		0,         // magic
		4, 4 + 23, // nonce
		4 + 24, len(w) - 1, // ciphertext, tag
	} {
		bad := append([]byte(nil), w...)
		bad[pos] ^= 0x01
		if _, err := Unwrap(kek, bad, refA, 1); !errors.Is(err, ErrUnwrap) {
			t.Errorf("tamper at byte %d accepted", pos)
		}
	}
	if _, err := Unwrap(kek, w[:len(w)-1], refA, 1); !errors.Is(err, ErrUnwrap) {
		t.Error("truncated wrap accepted")
	}
}

func TestWrapUsesFreshNonce(t *testing.T) {
	kek := mustKEK(t)
	dek := mustKEK(t)
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		w, err := Wrap(kek, dek, refA, 1)
		if err != nil {
			t.Fatal(err)
		}
		n := string(w[4:28])
		if seen[n] {
			t.Fatalf("nonce reused after %d wraps", i)
		}
		seen[n] = true
	}
}

func TestRefValidation(t *testing.T) {
	kek := mustKEK(t)
	for _, r := range []string{"", "short", "../../etc", "conn/aaaaaaaa", "conn.aaaaaaa", "conn aaaaaaaa"} {
		if _, err := Wrap(kek, mustKEK(t), r, 1); !errors.Is(err, ErrBadRef) {
			t.Errorf("ref %q accepted", r)
		}
	}
	if _, err := Wrap(kek, mustKEK(t), refA, 0); !errors.Is(err, ErrBadGen) {
		t.Error("generation 0 accepted")
	}
}

func TestStoredDEK(t *testing.T) {
	dir := t.TempDir()
	kek := mustKEK(t)
	for _, r := range []string{refA, refB} {
		if err := os.Mkdir(filepath.Join(dir, r), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	dek, err := CreateDEK(dir, kek, refA, 1)
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, refA, "dek-1.wrapped")
	fi, err := os.Stat(p)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("wrapped DEK missing or not 0600")
	}
	got, err := LoadDEK(dir, kek, refA, 1)
	if err != nil || !bytes.Equal(got, dek) {
		t.Fatal("stored DEK did not round trip")
	}
	if _, err := CreateDEK(dir, kek, refA, 1); !errors.Is(err, ErrDEKExists) {
		t.Error("existing DEK overwritten")
	}
	if _, err := LoadDEK(dir, kek, refA, 2); !errors.Is(err, ErrDEKMissing) {
		t.Error("missing generation loaded")
	}
	// Moving A's wrapped DEK into B's directory, or renaming it to another
	// generation, must not unwrap.
	raw, _ := os.ReadFile(p)
	os.WriteFile(filepath.Join(dir, refB, "dek-1.wrapped"), raw, 0o600)
	os.WriteFile(filepath.Join(dir, refA, "dek-2.wrapped"), raw, 0o600)
	if _, err := LoadDEK(dir, kek, refB, 1); !errors.Is(err, ErrUnwrap) {
		t.Error("A's DEK opened as B")
	}
	if _, err := LoadDEK(dir, kek, refA, 2); !errors.Is(err, ErrUnwrap) {
		t.Error("generation 1 DEK opened as generation 2")
	}
}

func TestSQLCipherKeyDerivation(t *testing.T) {
	dek := bytes.Repeat([]byte{1}, 32)
	k1, err := SQLCipherKey(dek)
	if err != nil || len(k1) != 32 {
		t.Fatal("derive failed")
	}
	k2, _ := SQLCipherKey(dek)
	if !bytes.Equal(k1, k2) || bytes.Equal(k1, dek) {
		t.Fatal("derivation not deterministic or equals DEK")
	}
	lk, _ := LogIDKey(dek)
	if bytes.Equal(lk, k1) {
		t.Fatal("log key equals store key")
	}
}
