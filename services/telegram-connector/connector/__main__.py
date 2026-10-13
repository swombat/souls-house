"""python -m connector: the Telegram connector process.

Environment (see ../README.md):

  COMMS_STORE_KEY        at least 32 characters; seals sessions and secrets
  COMMS_COMMAND_KEY      the same value as Rails's COMMS_COMMAND_KEY (≥ 32)
  COMMS_COMMAND_KEY_ID   default k1, as Rails
  COMMS_COMMAND_KEY_PREVIOUS, COMMS_COMMAND_KEY_PREVIOUS_ID   during a rotation
  COMMS_RAILS_URL        e.g. http://souls-house-web:3000 (no path)
  COMMS_TLS_CERT, COMMS_TLS_KEY, COMMS_TLS_CLIENT_CA, COMMS_TLS_CLIENT_NAME
  COMMS_LISTEN           default 0.0.0.0:8443
  COMMS_DATA_DIR         default /data
  TELEGRAM_API_ID, TELEGRAM_API_HASH   the application credentials
  TELEGRAM_PROVIDER      telethon (default) or fake (needs COMMS_ALLOW_FAKE=1)

It refuses to start, logging a fixed reason and no value, if any is missing
or malformed.
"""

import asyncio
import json
import logging
import os
import signal
import sys
import urllib.parse

import aiohttp
from aiohttp import web

from . import harden, server
from .account import Settings
from .lease import Held, Lease
from .manager import Manager
from .store import Crypto, Store


class JsonFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({"level": record.levelname.lower(), "logger": record.name, "msg": record.getMessage()})


log = logging.getLogger("telegram")


def refuse(reason):
    log.error("startup refused: reason=%s", reason)
    return 2


def setup_logging():
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(logging.INFO)
    # Telethon's own messages name channels and peers; only its errors pass.
    logging.getLogger("telethon").setLevel(logging.ERROR)
    logging.getLogger("aiohttp.access").setLevel(logging.ERROR)


def rails_poster(base, session):
    async def post(path, body, headers):
        async with session.post(base + path, data=body, headers=headers) as response:
            try:
                data = await response.json(content_type=None)
            except Exception:
                data = {}
            return response.status, data if isinstance(data, dict) else {}
    return post


def telegram_factory(env):
    provider = env.get("TELEGRAM_PROVIDER", "telethon")
    if provider == "fake":
        if env.get("COMMS_ALLOW_FAKE") != "1":
            raise ValueError("fake_not_allowed")
        from .fake import World
        world = World(env.get("TELEGRAM_FAKE_DIR") or "")
        return world.factory, world
    if provider != "telethon":
        raise ValueError("provider")
    api_id, api_hash = env.get("TELEGRAM_API_ID", ""), env.get("TELEGRAM_API_HASH", "")
    if not api_id.isdigit() or len(api_hash) < 16:
        raise ValueError("telegram_app")
    from .telegram import RealTelegram
    return (lambda session: RealTelegram(int(api_id), api_hash, session)), None


async def run(env):
    try:
        harden.apply()
    except RuntimeError:
        return refuse("harden")
    store_key = env.get("COMMS_STORE_KEY", "")
    if len(store_key) < 32:
        return refuse("store_key")
    command_key = env.get("COMMS_COMMAND_KEY", "")
    if len(command_key) < 32:
        return refuse("command_key")
    keys = {env.get("COMMS_COMMAND_KEY_ID") or "k1": command_key}
    previous = env.get("COMMS_COMMAND_KEY_PREVIOUS", "")
    if previous:
        if len(previous) < 32 or not env.get("COMMS_COMMAND_KEY_PREVIOUS_ID"):
            return refuse("previous_command_key")
        keys[env["COMMS_COMMAND_KEY_PREVIOUS_ID"]] = previous
    rails_url = env.get("COMMS_RAILS_URL", "")
    parsed = urllib.parse.urlparse(rails_url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.path not in ("", "/"):
        return refuse("rails_url")
    try:
        context = server.tls_context(env.get("COMMS_TLS_CERT"), env.get("COMMS_TLS_KEY"), env.get("COMMS_TLS_CLIENT_CA"))
    except server.TLSError:
        return refuse("tls")
    data_dir = env.get("COMMS_DATA_DIR", "/data")
    if not os.path.isdir(data_dir):
        return refuse("data_dir")
    try:
        factory, world = telegram_factory(env)
    except ValueError as error:
        return refuse(str(error))
    listen = env.get("COMMS_LISTEN", "0.0.0.0:8443")
    host, _, port = listen.rpartition(":")
    if not port.isdigit():
        return refuse("listen")

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)

    # Single ownership: no store, no client, no server until the lease is
    # ours. While another process holds it, this one waits, unavailable.
    lease = Lease(data_dir)
    waiting = False
    while True:
        try:
            lease.try_acquire()
            break
        except Held:
            if not waiting:
                log.warning("waiting for the data lease (another connector holds it)")
                waiting = True
        except OSError:
            return refuse("lease")
        try:
            await asyncio.wait_for(stop.wait(), 2)
            return 0
        except asyncio.TimeoutError:
            pass

    store = Store(os.path.join(data_dir, "telegram.sqlite3"), Crypto(store_key))
    fault = env.get("COMMS_FAULT")
    if fault and world is not None:
        # The fake-provider e2e kills the process at a named point inside
        # the ingest path, to prove nothing is lost (never in production).
        def crash(name, after=fault):
            if name == after and world.should_crash(name):
                os._exit(137)
        store.fault = crash

    timeout = aiohttp.ClientTimeout(total=20)
    async with aiohttp.ClientSession(timeout=timeout) as http:
        manager = Manager(store, factory, rails_poster(rails_url.rstrip("/"), http),
                          settings=world.settings() if world else Settings(),
                          log_key=store_key.encode())
        app = server.make_app(manager, store, keys, env.get("COMMS_TLS_CLIENT_NAME") or None)
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        site = web.TCPSite(runner, host or "0.0.0.0", int(port), ssl_context=context)
        await site.start()
        await manager.boot()
        log.info("started")
        await stop.wait()
        await runner.cleanup()
        await manager.close()
    lease.release()
    log.info("stopped")
    return 0


def main():
    setup_logging()
    sys.exit(asyncio.run(run(dict(os.environ))))


if __name__ == "__main__":
    main()
