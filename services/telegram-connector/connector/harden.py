"""Process hardening, as the WhatsApp connector does: no core dumps (they
could hold a session key, a password or messages), not ptrace-dumpable,
private file modes."""

import ctypes
import os
import resource

PR_SET_DUMPABLE = 4


def apply():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.umask(0o077)
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "prctl")
    except (OSError, AttributeError):
        raise RuntimeError("harden")
