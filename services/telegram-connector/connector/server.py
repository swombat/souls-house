"""The command server: POST /connections/<svc_id>/<operation> and GET
/healthz, over mutual TLS only.

TLS fails closed: without the connector's certificate and key and the house
CA that signed Rails's client certificate, the process does not start. Every
connection must present a client certificate the CA signed; with
COMMS_TLS_CLIENT_NAME set, its CN or a DNS SAN must be that name (rails).
Commands are then verified (commands.verify): key id, signature, freshness,
replay, body bound to the path. Bodies are never logged.
"""

import json
import logging
import re
import ssl
import time

from aiohttp import web

from . import commands
from .manager import OPERATIONS

log = logging.getLogger("telegram.server")

MAX_COMMAND_BYTES = 16 * 1024
CONNECTION_REF = re.compile(r"\Asvc_[0-9]{1,18}\Z")


class TLSError(Exception):
    pass


def tls_context(cert, key, client_ca):
    if not (cert and key and client_ca):
        raise TLSError("tls")
    try:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, key)
        context.load_verify_locations(cafile=client_ca)
    except (OSError, ssl.SSLError):
        raise TLSError("tls") from None
    context.verify_mode = ssl.CERT_REQUIRED
    return context


def client_name_matches(peercert, name):
    if not name:
        return True
    if not peercert:
        return False
    for rdn in peercert.get("subject", ()):
        for key, value in rdn:
            if key == "commonName" and value == name:
                return True
    return any(kind == "DNS" and value == name for kind, value in peercert.get("subjectAltName", ()))


def reply(status, body):
    return web.json_response(body, status=status, headers={"Cache-Control": "no-store"},
                             dumps=lambda value: json.dumps(value, ensure_ascii=False))


def make_app(manager, store, keys, client_name=None, clock=time.time):
    async def healthz(_request):
        return reply(200, {"status": "ok"})

    async def command(request):
        transport = request.transport
        peercert = transport.get_extra_info("peercert") if transport else None
        if not client_name_matches(peercert, client_name):
            log.warning("command refused: reason=client_name")
            return reply(403, {"error": "client_not_allowed"})
        ref = request.match_info["ref"]
        operation = request.match_info["operation"]
        if not CONNECTION_REF.match(ref) or operation not in OPERATIONS:
            return reply(404, {"error": "not_found"})
        try:
            raw = bytearray(await request.read())
        except web.HTTPRequestEntityTooLarge:
            return reply(413, {"error": "body_too_large"})
        now = int(clock())
        try:
            fields = commands.verify(
                keys=keys, headers=request.headers, connection=ref, operation=operation, body=bytes(raw), now=now,
                consume=lambda command_id: store.consume_command_id(command_id, now, commands.NONCE_RETENTION))
        except commands.Refused as refused:
            log.warning("command refused: op=%s reason=%s", operation, refused.code)
            return reply(refused.status, {"error": refused.code})
        finally:
            raw[:] = b"\0" * len(raw)  # the body may hold a password or a secret
        status, body = await manager.command(ref, operation, fields)
        fields.clear()
        return reply(status, body)

    app = web.Application(client_max_size=MAX_COMMAND_BYTES)
    app.router.add_get("/healthz", healthz)
    app.router.add_post("/connections/{ref}/{operation}", command)
    return app
