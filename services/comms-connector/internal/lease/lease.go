// Package lease enforces one worker per connection with an exclusive,
// non-blocking flock on <dataDir>/.leases/<ref> (keys.LeasePath). The kernel
// drops the lock when the process dies, so a crashed worker never leaves a
// stale lease.
//
// The lease file lives outside the connection's directory and is never
// deleted. A flock belongs to an inode: were the file deleted (with the
// directory, on unpair) and recreated, a second worker could lock the new
// inode while the first still held the old one, and both would run.
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

// Acquire takes the lease at path, creating the file (and its directory)
// if needed.
func Acquire(path string) (*Lease, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, ErrLease
	}
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
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
