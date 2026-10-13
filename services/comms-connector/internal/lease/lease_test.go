package lease

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestSecondAcquisitionFailsUntilRelease(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".leases", "svc_1")
	l1, err := Acquire(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Acquire(path); !errors.Is(err, ErrHeld) {
		t.Fatalf("second acquisition: got %v, want ErrHeld", err)
	}
	if err := l1.Release(); err != nil {
		t.Fatal(err)
	}
	l2, err := Acquire(path)
	if err != nil {
		t.Fatalf("acquisition after release failed: %v", err)
	}
	l2.Release()
}

// TestSecondProcess holds the lease here and starts a child process that
// tries to take it. The child must fail with the fixed message.
func TestSecondProcess(t *testing.T) {
	if os.Getenv("LEASE_HELPER_DIR") != "" {
		t.Skip("helper")
	}
	dir := filepath.Join(t.TempDir(), "lease")
	l, err := Acquire(dir)
	if err != nil {
		t.Fatal(err)
	}
	child := func() (int, string) {
		cmd := exec.Command(os.Args[0], "-test.run=^TestLeaseHelperProcess$")
		cmd.Env = append(os.Environ(), "LEASE_HELPER_DIR="+dir)
		out, _ := cmd.CombinedOutput()
		return cmd.ProcessState.ExitCode(), string(out)
	}
	code, out := child()
	if code != 3 || !strings.Contains(out, ErrHeld.Error()) || strings.Contains(out, dir) {
		t.Fatalf("child while held: exit %d, output %q", code, out)
	}
	l.Release()
	if code, out := child(); code != 0 {
		t.Fatalf("child after release: exit %d, output %q", code, out)
	}
}

func TestLeaseHelperProcess(t *testing.T) {
	dir := os.Getenv("LEASE_HELPER_DIR")
	if dir == "" {
		t.Skip("only runs as a child of TestSecondProcess")
	}
	l, err := Acquire(dir)
	if err != nil {
		os.Stderr.WriteString(err.Error() + "\n")
		os.Exit(3)
	}
	l.Release()
	os.Exit(0)
}
