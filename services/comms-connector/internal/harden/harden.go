// Package harden applies the process-level protections from spec §6b(4).
package harden

import (
	"errors"
	"os"
	"runtime/debug"

	"golang.org/x/sys/unix"
)

var (
	ErrTraceback = errors.New("GOTRACEBACK must be unset or none")
	ErrHarden    = errors.New("process hardening failed")
)

// Apply refuses a GOTRACEBACK other than unset/"none", then marks the process
// non-dumpable (no core, no same-uid ptrace or /proc/<pid>/mem) and sets the
// core rlimit to zero. It also restricts the umask so the store, its -wal and
// -shm, the lease and the wrapped DEKs are created 0600.
func Apply() error {
	switch os.Getenv("GOTRACEBACK") {
	case "", "none":
	default:
		return ErrTraceback
	}
	debug.SetTraceback("none")
	if err := unix.Prctl(unix.PR_SET_DUMPABLE, 0, 0, 0, 0); err != nil {
		return ErrHarden
	}
	if err := unix.Setrlimit(unix.RLIMIT_CORE, &unix.Rlimit{Cur: 0, Max: 0}); err != nil {
		return ErrHarden
	}
	unix.Umask(0o077)
	return nil
}

// Dumpable reports PR_GET_DUMPABLE (for tests).
func Dumpable() (int, error) {
	r, err := unix.PrctlRetInt(unix.PR_GET_DUMPABLE, 0, 0, 0, 0)
	return r, err
}
