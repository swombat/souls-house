"""Single ownership of the data directory (Mira's S2a boundary 1).

The process takes an exclusive, non-blocking flock on <data>/.lease before it
opens the store or any Telegram client, and holds it for its whole life. The
kernel drops it when the process exits, however it exits, so a replacement
container (or a straggler from an overlapping deploy, or a second container
started by hand on the same volume) cannot open a session until the old
process is gone: it waits, unavailable, and never starts a client.

The lease file is never deleted: a flock belongs to an inode, and a recreated
file would be a second, independent lock.
"""

import fcntl
import os


class Held(Exception):
    pass


class Lease:
    def __init__(self, data_dir):
        self.path = os.path.join(data_dir, ".lease")
        self.fd = None

    def try_acquire(self):
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            raise Held()
        except OSError:
            os.close(fd)
            raise
        os.ftruncate(fd, 0)
        os.write(fd, str(os.getpid()).encode())
        self.fd = fd
        return self

    def release(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
