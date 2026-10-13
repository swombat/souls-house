"""Sends a connection's outbox to Rails, in order (proposal §5a).

Each event is one POST to /internal/comms/connections/<ref>/events, signed
with the connection's callback secret the way app/lib/comms_signature.rb
verifies it. Rails answers a sequenced event with the highest sequence it has
committed, and rows are marked delivered only up to that. A 409 carries the
committed sequence too. Any other failure is retried later, in order; a row
is never skipped.
"""

import hashlib
import hmac
import logging
import secrets
import time

log = logging.getLogger("telegram.rails")


def signed_headers(secret, connection, path, body, now=None, nonce=None):
    timestamp = str(int(time.time() if now is None else now))
    nonce = nonce or secrets.token_hex(16)
    signed = "\n".join([connection, "POST", path, timestamp, nonce, body.decode()])
    return {
        "Content-Type": "application/json",
        "X-Comms-Connection": connection,
        "X-Comms-Timestamp": timestamp,
        "X-Comms-Nonce": nonce,
        "X-Comms-Signature": hmac.new(secret.encode(), signed.encode(), hashlib.sha256).hexdigest(),
    }


def events_path(ref):
    return f"/internal/comms/connections/{ref}/events"


async def deliver_pending(store, ref, post, batch=50):
    """Delivers what it can. `post(path, body, headers)` returns (status, json).
    Returns the number of rows newly marked delivered; stops at the first
    failure so order is kept."""
    secret = store.callback_secret(ref)
    if not secret:
        return 0
    delivered = 0
    for row in store.pending(ref, batch):
        body = row["body"].encode()
        path = events_path(ref)
        try:
            status, reply = await post(path, body, signed_headers(secret, ref, path, body))
        except Exception as error:  # network, timeout
            log.warning("delivery to Rails failed for %s seq %s: %s", ref, row["seq"], type(error).__name__)
            return delivered
        committed = reply.get("committed_seq") if isinstance(reply, dict) else None
        if status in (200, 409) and isinstance(committed, int):
            store.mark_delivered(ref, committed)
            if committed < row["seq"]:
                # A gap: Rails wants an earlier row, which is still pending
                # unless it was committed. Start again from the oldest.
                log.warning("Rails reports sequence gap for %s at %s (committed %s)", ref, row["seq"], committed)
                return delivered
            delivered += 1
            if reply.get("skipped"):
                log.info("Rails skipped obsolete event %s for %s: %s", row["seq"], ref, reply["skipped"])
            continue
        error = reply.get("error") if isinstance(reply, dict) else None
        log.warning("Rails refused %s seq %s: %s %s", ref, row["seq"], status, error)
        return delivered
    return delivered
