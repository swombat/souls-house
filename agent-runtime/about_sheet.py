"""The resident's sheet about souls.house itself (#566).

At the start of a fresh session the runtime asks the house for its current
sheet (GET /api/v1/about_house, rendered from the release the house is
running) and keeps it on disk. A failed fetch never leaves a resident mute:
the last good copy stays, and the hosting note says how old it is. A
container that has never reached the house falls back to the copy baked into
the image, which carries its own date.
"""

import io
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HEADING = "# About souls.house"
MAX_BYTES = 64 * 1024
TIMEOUT = 4
# A copy younger than this is not fetched again: one fetch per burst of fresh
# sessions is enough, and the house is not asked on every wake.
FRESH_SECONDS = 10 * 60
ENDPOINT = "/api/v1/about_house"


def live_path():
    override = os.environ.get("SOULSHOUSE_ABOUT_SHEET_PATH")
    if override:
        return Path(override)
    return Path.home() / ".cache" / "souls-house" / "about-souls-house.md"


def baked_path():
    docs = os.environ.get("AGENT_RUNTIME_DOCS_PATH", "/usr/local/share/helixkit-agent")
    return Path(docs) / "about-souls-house.md"


class RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: the request carries the house credential, and
    urllib would re-send it to whatever origin the Location names."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urllib.parse.urlsplit(newurl).netloc or newurl
        message = (f"refused to follow a redirect ({code}) to {target} with the house credential; "
                   "check SOULSHOUSE_APP_URL")
        raise urllib.error.HTTPError(req.full_url, code, message, headers, io.BytesIO(message.encode()))


NO_REDIRECT_OPENER = urllib.request.build_opener(RefuseRedirects)


def _http_get(url, token):
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept": "text/markdown"})
    with NO_REDIRECT_OPENER.open(request, timeout=TIMEOUT) as response:
        if response.status != 200:
            raise OSError(f"HTTP {response.status}")
        return response.read(MAX_BYTES + 1)


def refresh(fetch=None, now=None, path=None):
    """Fetch the sheet and write it. Returns "fetched", "fresh" or "failed: <why>"."""
    now = time.time() if now is None else now
    path = path or live_path()
    try:
        if path.exists() and now - path.stat().st_mtime < FRESH_SECONDS:
            return "fresh"
    except OSError:
        pass
    base = (os.environ.get("SOULSHOUSE_APP_URL") or os.environ.get("HELIXKIT_APP_URL") or "").rstrip("/")
    token = os.environ.get("SOULSHOUSE_BEARER_TOKEN") or os.environ.get("HELIXKIT_BEARER_TOKEN") or ""
    if not base or not token:
        return "failed: no house address or key"
    try:
        body = (fetch or _http_get)(base + ENDPOINT, token)
        if len(body) > MAX_BYTES:
            return "failed: too large"
        text = body.decode("utf-8")
        if not text.startswith(HEADING):
            return "failed: not a sheet"
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(text, encoding="utf-8")
        tmp.replace(path)
        return "fetched"
    except Exception as error:  # Never fail a turn over this.
        # The reason, never the key: a refused redirect names only the host.
        return f"failed: {type(error).__name__}: {error}"


def _age(seconds):
    seconds = max(0, int(seconds))
    if seconds < 3600:
        return "under an hour"
    if seconds < 2 * 86400:
        hours = seconds // 3600
        return f"{hours} hour{'s' if hours != 1 else ''}"
    return f"{seconds // 86400} days"


def current(now=None):
    """(path, age_seconds or None, source) of the copy a resident should read, or None."""
    now = time.time() if now is None else now
    live = live_path()
    if live.is_file():
        return live, now - live.stat().st_mtime, "live"
    baked = baked_path()
    if baked.is_file():
        return baked, None, "baked"
    return None


def hosting_note(status, now=None):
    """The hosting-context lines about the sheet, given this session's refresh status."""
    found = current(now)
    pointer = (
        "The house's /features page and the account's owner also know what it offers."
    )
    if not found:
        return (
            "## About souls.house\n"
            "No sheet about souls.house is available in this container yet. The house's "
            "/features page and the account's owner know what it offers."
        )
    path, age, source = found
    if source == "live" and not status.startswith("failed"):
        where = f"{path}, a dated sheet this house generated from the release it is running"
    elif source == "live":
        where = (
            f"{path}, a dated sheet this house generated; the house could not be reached for a new "
            f"one this session, so this copy is {_age(age)} old"
        )
    else:
        where = (
            f"{path}, the copy built into this runtime image; the house has not been reached for a "
            "current one, so check its date before relying on it"
        )
    return (
        "## About souls.house\n"
        f"There is a sheet about souls.house itself (what it is, what it offers, apps, plans and "
        f"prices, the Field) at {where}. {pointer}"
    )


def session_note(fetch=None, now=None):
    return hosting_note(refresh(fetch=fetch, now=now), now=now)
