package server

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"io"
	"log/slog"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"services/comms-connector/internal/command"
	"services/comms-connector/internal/sig"
)

type issued struct {
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
}

func issue(t *testing.T, cn string, parent *issued, server bool) *issued {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	serial, _ := rand.Int(rand.Reader, big.NewInt(1<<62))
	tmpl := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: cn},
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour),
	}
	signer, signerKey := tmpl, key
	if parent == nil {
		tmpl.IsCA, tmpl.BasicConstraintsValid, tmpl.KeyUsage = true, true, x509.KeyUsageCertSign
	} else {
		signer, signerKey = parent.cert, parent.key
		if server {
			tmpl.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
			tmpl.IPAddresses = []net.IP{net.ParseIP("127.0.0.1")}
		} else {
			tmpl.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
		}
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, signer, &key.PublicKey, signerKey)
	if err != nil {
		t.Fatal(err)
	}
	c, _ := x509.ParseCertificate(der)
	return &issued{cert: c, key: key}
}

func (i *issued) write(t *testing.T, dir, name string) (certPath, keyPath string) {
	certPath, keyPath = filepath.Join(dir, name+".pem"), filepath.Join(dir, name+".key")
	os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: i.cert.Raw}), 0o600)
	kb, _ := x509.MarshalECPrivateKey(i.key)
	os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}), 0o600)
	return
}

func (i *issued) tlsCert() tls.Certificate {
	return tls.Certificate{Certificate: [][]byte{i.cert.Raw}, PrivateKey: i.key}
}

type recorder struct {
	mu    sync.Mutex
	calls []string
}

func (r *recorder) StartPairing(_ context.Context, ref, secret string, version int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, "start_pairing "+ref+" "+secret+" "+strconv.FormatInt(version, 10))
	return nil
}

func (r *recorder) Unpair(_ context.Context, ref string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, "unpair "+ref)
	return nil
}

type tlsRig struct {
	srv          *httptest.Server
	ca           *issued
	rails, other *issued
	foreignCA    *issued
	rec          *recorder
	logs         *syncBuf
}

func newTLSRig(t *testing.T) *tlsRig {
	dir := t.TempDir()
	ca := issue(t, "house test CA", nil, false)
	srvCert := issue(t, "souls-house-comms-whatsapp", ca, true)
	certPath, keyPath := srvCert.write(t, dir, "server")
	caPath, _ := ca.write(t, dir, "ca")
	cfg, err := TLSConfig(certPath, keyPath, caPath, "rails")
	if err != nil {
		t.Fatal(err)
	}
	r := &tlsRig{ca: ca, rec: &recorder{}, logs: &syncBuf{}}
	r.rails = issue(t, "rails", ca, false)
	r.other = issue(t, "mallory", ca, false)
	r.foreignCA = issue(t, "foreign CA", nil, false)
	h := &Handler{
		Verifier: command.NewVerifier("k1", []byte("test-command-key"), func() time.Time { return time.Now().Add(-time.Second) }),
		Commands: r.rec,
		Log:      slog.New(slog.NewJSONHandler(r.logs, nil)),
	}
	r.srv = httptest.NewUnstartedServer(h)
	r.srv.TLS = cfg
	r.srv.StartTLS()
	t.Cleanup(r.srv.Close)
	return r
}

func (r *tlsRig) client(cert *issued) *http.Client {
	pool := x509.NewCertPool()
	pool.AddCert(r.ca.cert)
	tc := &tls.Config{RootCAs: pool}
	if cert != nil {
		tc.Certificates = []tls.Certificate{cert.tlsCert()}
	}
	return &http.Client{Transport: &http.Transport{TLSClientConfig: tc}, Timeout: 5 * time.Second}
}

// command builds a request exactly as CommsConnector.command does.
func (r *tlsRig) command(t *testing.T, ref, op string, fields map[string]any, key string) *http.Request {
	id, _ := sig.Nonce()
	at := time.Now().Unix()
	body := map[string]any{}
	for k, v := range fields {
		body[k] = v
	}
	body["connection"], body["operation"], body["command_id"], body["issued_at"] = ref, op, id, at
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, r.srv.URL+"/connections/"+ref+"/"+op, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(sig.HeaderKeyID, "k1")
	req.Header.Set(sig.HeaderCommandID, id)
	req.Header.Set(sig.HeaderIssuedAt, strconv.FormatInt(at, 10))
	req.Header.Set(sig.HeaderCommand, sig.SignCommand([]byte(key), "k1", ref, op, id, strconv.FormatInt(at, 10), raw))
	return req
}

func do(t *testing.T, c *http.Client, req *http.Request) (int, string, error) {
	resp, err := c.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b), nil
}

func TestSignedCommandOverMutualTLS(t *testing.T) {
	r := newTLSRig(t)
	status, body, err := do(t, r.client(r.rails), r.command(t, "svc_7", "start_pairing",
		map[string]any{"callback_secret": secret, "callback_secret_version": 3}, "test-command-key"))
	if err != nil || status != 200 || !strings.Contains(body, `"pairing"`) {
		t.Fatalf("start_pairing: %d %s %v", status, body, err)
	}
	status, _, _ = do(t, r.client(r.rails), r.command(t, "svc_7", "unpair", nil, "test-command-key"))
	if status != 200 {
		t.Fatalf("unpair: %d", status)
	}
	want := []string{"start_pairing svc_7 " + secret + " 3", "unpair svc_7"}
	if strings.Join(r.rec.calls, "|") != strings.Join(want, "|") {
		t.Fatalf("calls %v", r.rec.calls)
	}
	if strings.Contains(r.logs.String(), secret) {
		t.Fatal("secret logged")
	}
}

func TestTransportRefusesAnyoneButRails(t *testing.T) {
	r := newTLSRig(t)
	for name, c := range map[string]*http.Client{
		"no client certificate":          r.client(nil),
		"certificate from another CA":    r.client(r.foreignCA),
		"house CA, but not Rails's name": r.client(r.other),
	} {
		_, _, err := do(t, c, r.command(t, "svc_7", "unpair", nil, "test-command-key"))
		if err == nil {
			t.Errorf("%s: request went through", name)
		}
	}
	if len(r.rec.calls) != 0 {
		t.Fatalf("commands ran: %v", r.rec.calls)
	}
}

func TestBadCommandsAreRefusedBeforeAnythingRuns(t *testing.T) {
	r := newTLSRig(t)
	c := r.client(r.rails)
	if status, body, _ := do(t, c, r.command(t, "svc_7", "unpair", nil, "wrong-key")); status != 401 || !strings.Contains(body, "bad_signature") {
		t.Fatalf("wrong key: %d %s", status, body)
	}
	replay := r.command(t, "svc_7", "unpair", nil, "test-command-key")
	raw, _ := io.ReadAll(replay.Body)
	replay.Body = io.NopCloser(bytes.NewReader(raw))
	do(t, c, replay)
	again, _ := http.NewRequest(http.MethodPost, replay.URL.String(), bytes.NewReader(raw))
	again.Header = replay.Header.Clone()
	if status, body, _ := do(t, c, again); status != 401 || !strings.Contains(body, "replayed_command") {
		t.Fatalf("replay: %d %s", status, body)
	}
	if status, _, _ := do(t, c, r.command(t, "svc_7", "start_pairing", nil, "test-command-key")); status != 422 {
		t.Fatalf("start_pairing without a secret: %d", status)
	}
	req, _ := http.NewRequest(http.MethodPost, r.srv.URL+"/connections/..%2Fetc/unpair", nil)
	if status, _, _ := do(t, c, req); status != 404 {
		t.Fatalf("traversal ref: %d", status)
	}
	if got := strings.Join(r.rec.calls, "|"); got != "unpair svc_7" {
		t.Fatalf("calls %q", got)
	}
}

func TestHealthz(t *testing.T) {
	r := newTLSRig(t)
	req, _ := http.NewRequest(http.MethodGet, r.srv.URL+"/healthz", nil)
	if status, _, err := do(t, r.client(r.rails), req); err != nil || status != 200 {
		t.Fatalf("healthz %d %v", status, err)
	}
}
