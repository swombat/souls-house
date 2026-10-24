package keys

import (
	"bytes"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
)

func master() []byte { return bytes.Repeat([]byte{7}, KeySize) }

func TestParseStoreKey(t *testing.T) {
	good := base64.StdEncoding.EncodeToString(master())
	if k, err := ParseStoreKey(good); err != nil || !bytes.Equal(k, master()) {
		t.Fatal("canonical key refused")
	}
	for _, bad := range []string{"", "not base64", base64.StdEncoding.EncodeToString(make([]byte, 31)),
		base64.StdEncoding.EncodeToString(make([]byte, 33)), good[:20] + "\n" + good[20:], base64.RawStdEncoding.EncodeToString(master())} {
		if _, err := ParseStoreKey(bad); !errors.Is(err, ErrStoreKey) {
			t.Errorf("%q accepted", bad)
		}
	}
}

// The derivation is pinned: a change here would make every existing store
// unreadable, which must be a deliberate migration, not an accident.
func TestStoreKeyIsHKDFOfRef(t *testing.T) {
	got, err := StoreKey(master(), "svc_42")
	if err != nil {
		t.Fatal(err)
	}
	want, _ := hkdf.Key(sha256.New, master(), nil, "comms-sqlcipher-v1\x00svc_42", 32)
	if !bytes.Equal(got, want) {
		t.Fatal("store key is not HKDF(COMMS_STORE_KEY, ref)")
	}
	other, _ := StoreKey(master(), "svc_43")
	if bytes.Equal(got, other) {
		t.Fatal("two connections share a store key")
	}
	if _, err := StoreKey(master(), "../svc_1"); !errors.Is(err, ErrBadRef) {
		t.Fatal("bad ref accepted")
	}
	if _, err := StoreKey(master()[:31], "svc_1"); !errors.Is(err, ErrStoreKey) {
		t.Fatal("short master accepted")
	}
}

func TestLogIDHidesRef(t *testing.T) {
	id, err := LogID(master(), "svc_42")
	if err != nil || len(id) != 16 || strings.Contains(id, "svc_") {
		t.Fatalf("log id %q", id)
	}
	again, _ := LogID(master(), "svc_42")
	other, _ := LogID(master(), "svc_43")
	if id != again || id == other {
		t.Fatal("log id not stable per ref")
	}
}
