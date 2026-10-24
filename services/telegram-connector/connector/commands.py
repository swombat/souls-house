"""Verifying Rails → connector commands (proposal §5; Rails side:
app/lib/comms_command_signature.rb).

The signed string is

  v1 LF key-id LF connection LF operation LF command-id LF unix-seconds LF sha256(body)

and the body repeats connection, operation, command id and issue time. A
command is refused if the key id is unknown, the signature is wrong, it is
older than MAX_AGE (or from the future), its id was seen before, or the body
disagrees with the signed headers or the path.
"""

import hashlib
import hmac
import json
import re

MAX_AGE = 60
NONCE_RETENTION = MAX_AGE * 3
COMMAND_ID = re.compile(r"\A[0-9a-f]{32}\Z")


class Refused(Exception):
    def __init__(self, code, status=401):
        super().__init__(code)
        self.code = code
        self.status = status


def signing_string(key_id, connection, operation, command_id, issued_at, body):
    return "\n".join(["v1", key_id, connection, operation, command_id, str(issued_at),
                      hashlib.sha256(body).hexdigest()])


def sign(key, key_id, connection, operation, command_id, issued_at, body):
    message = signing_string(key_id, connection, operation, command_id, issued_at, body)
    return hmac.new(key.encode(), message.encode(), hashlib.sha256).hexdigest()


def verify(*, keys, headers, connection, operation, body, now, consume):
    """Returns the parsed body. `keys` maps key id → key (current and, during
    a rotation, previous). `consume(command_id)` records the id and returns
    False if it was already seen."""
    key_id = headers.get("X-Comms-Key-Id", "")
    command_id = headers.get("X-Comms-Command-Id", "")
    issued_at = headers.get("X-Comms-Issued-At", "")
    signature = headers.get("X-Comms-Command-Signature", "")
    if not (key_id and command_id and issued_at and signature):
        raise Refused("missing_signature")
    key = keys.get(key_id)
    if not key:
        raise Refused("unknown_key")
    if not COMMAND_ID.match(command_id) or not issued_at.isdigit():
        raise Refused("bad_headers")
    expected = sign(key, key_id, connection, operation, command_id, issued_at, body)
    if not hmac.compare_digest(expected, signature):
        raise Refused("bad_signature")
    if abs(now - int(issued_at)) > MAX_AGE:
        raise Refused("stale_command")
    try:
        fields = json.loads(body)
    except ValueError:
        raise Refused("bad_json", 400)
    if not isinstance(fields, dict):
        raise Refused("bad_json", 400)
    if (fields.get("connection") != connection or fields.get("operation") != operation
            or fields.get("command_id") != command_id or str(fields.get("issued_at")) != issued_at):
        raise Refused("body_mismatch")
    if not consume(command_id):
        raise Refused("replayed_command")
    return fields
