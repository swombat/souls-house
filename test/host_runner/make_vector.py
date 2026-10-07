"""Regenerates test/fixtures/files/runner_signature_vector.json.

Ed25519 is deterministic, so a fixed key and request give a fixed signature.
The Python test checks the runner still produces it; the Rails test checks
Rails still verifies it. Together they pin the wire contract across languages.
"""
import base64
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "host-runner"))

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402

import souls_house_runner as runner  # noqa: E402

VECTOR_PATH = os.path.join(HERE, "..", "fixtures", "files", "runner_signature_vector.json")
SEED = bytes(range(32))
RUNNER_ID = "rnr_0123456789abcdef"
TIMESTAMP = 1_790_000_000
NONCE = "00112233445566778899aabbccddeeff"


def build():
    key = Ed25519PrivateKey.from_private_bytes(SEED)
    payload = {"token": "example-token", "public_key": runner.public_key_b64(key), "facts": {"provider_server_id": 4242}}
    body = runner.encode_body(payload)
    headers = runner.signed_headers(key, "POST", runner.ENROLL_PATH, body, RUNNER_ID, timestamp=TIMESTAMP, nonce=NONCE)
    return {
        "seed_b64": base64.b64encode(SEED).decode("ascii"),
        "public_key_b64": runner.public_key_b64(key),
        "method": "POST",
        "path": runner.ENROLL_PATH,
        "body": body.decode("utf-8"),
        "signing_string": runner.signing_string("POST", runner.ENROLL_PATH, body, RUNNER_ID, TIMESTAMP, NONCE),
        "headers": headers,
    }


if __name__ == "__main__":
    with open(VECTOR_PATH, "w") as handle:
        json.dump(build(), handle, indent=2, sort_keys=True)
        handle.write("\n")
