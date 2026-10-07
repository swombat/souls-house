"""Git helper for the explicitly granted import repository; no token in config."""
import os
import sys
from pathlib import Path

import yaml


def credentials(request, services, connection_id, repository):
    if request.get("protocol") != "https" or request.get("host") != "github.com":
        return None
    if request.get("path", "").removesuffix(".git").rstrip("/") != repository:
        return None
    for service in services.get("services", []):
        if service.get("connection_id") == connection_id and service.get("provider") == "github":
            token = service.get("credentials", {}).get("token")
            if isinstance(token, str) and token.startswith("github_pat_") and "\n" not in token and "\r" not in token:
                return {"username": "x-access-token", "password": token}
    return None


def main():
    if sys.argv[1:] != ["get"]:
        return
    request = dict(line.rstrip("\n").split("=", 1) for line in sys.stdin if "=" in line)
    services = yaml.safe_load(Path("/run/helixkit/services.yml").read_text()) or {}
    result = credentials(request, services, os.environ.get("SOULSHOUSE_GITHUB_IMPORT_CONNECTION"),
                         os.environ.get("SOULSHOUSE_GITHUB_IMPORT_REPOSITORY"))
    if result:
        # Git's private helper protocol, never an application log.
        for key, value in result.items():
            print(key + "=" + value)


if __name__ == "__main__":
    main()
