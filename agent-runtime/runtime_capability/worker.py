"""Runtime-owned discovery worker; stdout contains only the result protocol."""

import json
from pathlib import Path
import sys

from manifest import InvalidManifest, read_manifest, validate
from probes import probe


def check(identity_path):
    try:
        declarations = validate(read_manifest(
            str(Path(identity_path) / "runtime-requirements.yml")
        ))
    except FileNotFoundError:
        return {"status": "absent", "items": []}
    except InvalidManifest:
        return {"status": "invalid", "items": []}
    return {"status": "ok", "items": [
        {"channel": result.channel, "name": result.name, "state": result.state}
        for result in map(probe, declarations)
    ]}


if __name__ == "__main__":
    # The parent supplies its configured identity directory, not request data.
    try:
        result = check(sys.argv[1])
    except Exception:
        result = {"status": "error", "items": []}
    sys.stdout.write(json.dumps(result, separators=(",", ":")))
