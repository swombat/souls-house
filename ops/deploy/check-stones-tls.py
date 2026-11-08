#!/usr/bin/env python3
"""Independent public TLS expiry check; needs no host or account credentials."""
import os
import re
import socket
import ssl
import time


def check(domain):
    if not re.fullmatch(r"[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z]{2,}", domain):
        raise ValueError("Invalid stones monitor domain")
    host = "tls-check." + domain
    with socket.create_connection((host, 443), timeout=15) as tcp:
        with ssl.create_default_context().wrap_socket(tcp, server_hostname=host) as tls:
            cert = tls.getpeercert()
    if ssl.cert_time_to_seconds(cert["notAfter"]) < time.time() + 21 * 86400:
        raise ValueError("Public stone certificate has fewer than 21 days remaining")
    print("Public stone TLS chain/hostname verified; more than 21 days remain")


if __name__ == "__main__":
    check(os.environ["STONES_MONITOR_DOMAIN"])
