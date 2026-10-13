"""Sends a connection's outbox to Rails, in order (proposal §5a).

Each event is one POST to /internal/comms/connections/<ref>/events, signed
with the connection's callback secret the way app/lib/comms_signature.rb
verifies it. Rails answers a sequenced event with the highest sequence it has
committed, and rows are marked delivered only up to that. A 409 carries the
committed sequence too. Any other failure is retried later, in order; a row
is never skipped.

Two exceptions, both keeping the sequence without holes:
- 410 connection_revoked: the owner disconnected and the logout never reached
  the connector. The caller deletes the connection (Outcome.REVOKED).
- An event Rails refuses as invalid (422) or too large (413) POISON_LIMIT
  times in a row is replaced in place by a no-op, so it cannot block the rest.
"""

import enum
import hashlib
import hmac
import json
import logging
import secrets
import time

from .store import NOOP_EVENT

log = logging.getLogger("telegram.rails")

POISON_LIMIT = 5
# A sequence number far past anything real: Rails answers it with
# sequence_gap and the sequence it has committed, applying nothing.
PROBE_SEQ = 2 ** 53


class Outcome(enum.Enum):
    DONE = "done"          # nothing left that could be sent now
    FAILED = "failed"      # Rails unreachable or refusing; retry later
    REVOKED = "revoked"    # 410: delete the connection


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


async def post_event(store, ref, post, event):
    """One unsequenced event (login.qr, connector.availability), not stored.
    Returns the HTTP status, or None when Rails could not be reached."""
    secret = store.callback_secret(ref)
    if not secret:
        return None
    body = json.dumps(event, separators=(",", ":"), ensure_ascii=False).encode()
    path = events_path(ref)
    try:
        status, _reply = await post(path, body, signed_headers(secret, ref, path, body))
    except Exception as error:  # network, timeout
        log.warning("unsequenced event failed: %s", type(error).__name__)
        return None
    return status


async def learn_sequence(store, ref, post):
    """Once per process, before anything is delivered, asks Rails how far it
    has committed (a probe Rails answers with sequence_gap and its sequence,
    applying nothing). A store that is behind Rails, because it is fresh or
    was restored from an older copy of the volume, would otherwise number new
    rows at or below what Rails committed, and Rails would acknowledge them
    without applying them; store.reconcile_sequence renumbers them past it.
    Returns True once checked."""
    row = store.connection(ref)
    if row is None or store.sequence_checked(ref):
        return True
    secret = store.callback_secret(ref)
    if not secret:
        return False
    body = json.dumps(dict(NOOP_EVENT, seq=PROBE_SEQ), separators=(",", ":")).encode()
    path = events_path(ref)
    try:
        status, reply = await post(path, body, signed_headers(secret, ref, path, body))
    except Exception as error:
        log.warning("sequence probe failed: %s", type(error).__name__)
        return False
    committed = reply.get("committed_seq") if isinstance(reply, dict) else None
    if status == 409 and isinstance(committed, int):
        if store.reconcile_sequence(ref, committed) and row["next_seq"] > 1:
            log.warning("store is behind Rails (restored from an older copy?); "
                        "undelivered events renumbered past Rails' sequence")
        return True
    if status == 410:
        return False
    log.warning("sequence probe refused: %s", status)
    return False


class Deliverer:
    """Per-connection delivery state (the poison counter is in memory, so a
    restart starts it again, as for the WhatsApp connector)."""

    def __init__(self, store, ref, post, batch=50):
        self.store = store
        self.ref = ref
        self.post = post
        self.batch = batch
        self.refusals = {}

    async def run_once(self):
        """Delivers what it can. Returns (outcome, rows newly delivered); stops
        at the first failure so order is kept."""
        store, ref = self.store, self.ref
        secret = store.callback_secret(ref)
        if not secret:
            return Outcome.FAILED, 0
        if not await learn_sequence(store, ref, self.post):
            return Outcome.FAILED, 0
        delivered = 0
        while True:
            rows = store.pending(ref, self.batch)
            if not rows:
                return Outcome.DONE, delivered
            for row in rows:
                body = row["body"].encode()
                path = events_path(ref)
                try:
                    status, reply = await self.post(path, body, signed_headers(secret, ref, path, body))
                except Exception as error:  # network, timeout
                    log.warning("delivery failed: %s", type(error).__name__)
                    return Outcome.FAILED, delivered
                if status == 410:
                    return Outcome.REVOKED, delivered
                committed = reply.get("committed_seq") if isinstance(reply, dict) else None
                if status in (200, 409) and isinstance(committed, int):
                    if committed >= store.connection(ref)["next_seq"]:
                        # Rails has committed numbers this store never
                        # issued: nothing it acknowledges here was applied.
                        # Check the sequence again before sending anything.
                        log.warning("Rails is ahead of every event this store issued; checking the sequence again")
                        store.forget_sequence_check(ref)
                        return Outcome.FAILED, delivered
                    self.refusals.pop(row["seq"], None)
                    store.mark_delivered(ref, committed)
                    if committed < row["seq"]:
                        # A gap: Rails wants an earlier row, which is still
                        # pending unless it was committed. Start again from
                        # the oldest.
                        log.warning("sequence gap reported")
                        return Outcome.FAILED, delivered
                    delivered += 1
                    if reply.get("skipped"):
                        log.info("obsolete lifecycle event skipped: %s", reply["skipped"])
                    continue
                error = reply.get("error") if isinstance(reply, dict) else None
                if status in (413, 422):
                    count = self.refusals.get(row["seq"], 0) + 1
                    self.refusals = {row["seq"]: count}
                    if count >= POISON_LIMIT:
                        log.warning("event refused %s times (%s); replaced by a no-op", count, error)
                        store.replace_pending(ref, row["seq"], NOOP_EVENT)
                        self.refusals = {}
                        break  # read the rewritten row again
                else:
                    self.refusals = {}
                log.warning("Rails refused an event: %s %s", status, error)
                return Outcome.FAILED, delivered
