// Package lease enforces one worker per connection with an exclusive,
// non-blocking flock on <dataDir>/<ref>/lease. The kernel drops the lock when
// the process dies, so a crashed worker never leaves a stale lease.
package lease

import (
	"errors"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

var (
	// ErrHeld means another worker holds this connection. Content-free.
	ErrHeld = errors.New("connection lease is held by another worker")
	// ErrLease is any other failure to take the lease.
	ErrLease = errors.New("connection lease could not be taken")
)

type Lease struct{ f *os.File }

// Acquire takes the lease in connDir, which must exist.
func Acquire(connDir string) (*Lease, error) {
	f, err := os.OpenFile(filepath.Join(connDir, "lease"), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, ErrLease
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, ErrHeld
		}
		return nil, ErrLease
	}
	return &Lease{f: f}, nil
}

// Release drops the lock. Closing the descriptor releases it.
func (l *Lease) Release() error {
	if l == nil || l.f == nil {
		return nil
	}
	err := l.f.Close()
	l.f = nil
	if err != nil {
		return ErrLease
	}
	return nil
}
