package harden

import (
	"errors"
	"testing"

	"golang.org/x/sys/unix"
)

func TestRefusesTraceback(t *testing.T) {
	for _, v := range []string{"crash", "all", "single", "system", "1", "2"} {
		t.Setenv("GOTRACEBACK", v)
		if err := Apply(); !errors.Is(err, ErrTraceback) {
			t.Errorf("GOTRACEBACK=%s accepted", v)
		}
	}
}

func TestApply(t *testing.T) {
	t.Setenv("GOTRACEBACK", "none")
	if err := Apply(); err != nil {
		t.Fatal(err)
	}
	if d, err := Dumpable(); err != nil || d != 0 {
		t.Fatalf("dumpable = %d, %v", d, err)
	}
	var rl unix.Rlimit
	if err := unix.Getrlimit(unix.RLIMIT_CORE, &rl); err != nil || rl.Cur != 0 || rl.Max != 0 {
		t.Fatalf("core rlimit = %+v", rl)
	}
}
