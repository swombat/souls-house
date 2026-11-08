#!/usr/bin/env python3
"""Root-only operational notifier; no identity or DNS credentials in this file."""
import json
import sys
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError("Notification redirects are forbidden")


def main():
    if len(sys.argv) != 3 or any(len(s) > 2000 for s in sys.argv[1:]):
        raise SystemExit("Expected bounded subject and operational detail")
    config = json.load(open("/etc/house-deploy/stones-tls/notify.json"))
    if config["url"] != "https://souls.house/api/v1/conversations/erBWle/messages":
        raise SystemExit("Unexpected notification destination")
    content = "**Automated soulstones TLS notice** — " + sys.argv[1] + "\n\n" + sys.argv[2]
    request = urllib.request.Request(
        config["url"],
        data=json.dumps({"content": content}).encode(),
        headers={
            "Authorization": "Bearer " + config["token"],
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        opener = urllib.request.build_opener(NoRedirect)
        with opener.open(request, timeout=30) as response:
            result = json.load(response)
            message_id = result.get("message", {}).get("id")
            if not message_id:
                raise ValueError("No receipt")
            print("TLS notification receipt:", message_id)
    except Exception:
        raise SystemExit("TLS notification failed; no automatic retry or response disclosure")


if __name__ == "__main__":
    main()
