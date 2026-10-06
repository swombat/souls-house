"""Bootstrap only for new house-managed GitHub imports, never legacy homes.

The Rails approval is the authority, not an editable project-trust database.
This guard runs before repository hooks/sync. It does not kill existing code
or promise that resident-held credentials can be recalled.
"""
import json
import os
from pathlib import Path
import subprocess
import urllib.request

import imported_home


def fetch_approval():
    base = os.environ.get("SOULSHOUSE_APP_URL", "").rstrip("/")
    token = os.environ.get("SOULSHOUSE_BEARER_TOKEN", "")
    if not base or not token:
        raise ValueError("Managed import bootstrap requires its house approval endpoint")
    request = urllib.request.Request(
        base + "/api/v1/agent/github_import_approval",
        headers={"Authorization": "Bearer " + token},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        raw = response.read(65537)
    if len(raw) > 65536:
        raise ValueError("Oversized approval response")
    return json.loads(raw)


def check(fetch=fetch_approval):
    if not os.environ.get("SOULSHOUSE_GITHUB_IMPORT_ID"):
        return False
    root, manifest = imported_home.validate()
    result = fetch()
    expected = {
        "import_id": os.environ["SOULSHOUSE_GITHUB_IMPORT_ID"],
        "credential_fingerprint": os.environ.get("SOULSHOUSE_GITHUB_IMPORT_FINGERPRINT"),
        "repository": os.environ.get("SOULSHOUSE_GITHUB_IMPORT_REPOSITORY"),
        "branch": os.environ.get("SOULSHOUSE_GITHUB_IMPORT_BRANCH"),
        "portable_home_id": os.environ.get("SOULSHOUSE_PORTABLE_HOME_ID"),
        "home_profile": "portable_v1",
    }
    if result.get("approved") is not True or any(not value or result.get(key) != value for key, value in expected.items()):
        raise ValueError("Managed GitHub import approval changed; reapproval is required")
    if manifest["identity_id"] != expected["portable_home_id"]:
        raise ValueError("Managed import identity changed")
    if (result.get('sync_strategy', 'existing') != imported_home.sync_strategy() or
            result.get('sync_configuration', {}) != json.loads(os.environ.get('SOULSHOUSE_HOME_SYNC_CONFIGURATION', '{}'))):
        raise ValueError('Managed import sync selection changed')
    # Git configuration is host-generated, not copied from another installation.
    # credential.useHttpPath limits helper matching, not arbitrary resident code.
    commands = [
        ["remote", "set-url", "origin", "https://github.com/" + expected["repository"] + ".git"],
        ["config", "credential.useHttpPath", "true"],
        ["config", "--replace-all", "credential.helper", "!python3 /home/agent/github_import_credential.py"],
    ]
    for args in commands:
        subprocess.run(["git", "-c", "core.hooksPath=/dev/null", *args], cwd=root,
                       check=True, capture_output=True, timeout=10)
    return True


if __name__ == "__main__":
    try:
        check()
    except Exception:
        # No upstream response, configuration, token or repository script text.
        raise SystemExit("Managed GitHub import bootstrap refused; check house approval")
