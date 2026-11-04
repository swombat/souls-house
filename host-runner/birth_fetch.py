"""Fetch the runner this VM's user_data pins (#779).

cloud-init no longer carries the runner: user_data holds the config (with
`birth_bundle_sha256`), the units and this script. A systemd oneshot runs it
until the pinned bundle is installed, then it starts the runner. Stdlib only:
it runs before anything else is installed.

The enrollment token authorises exactly one read and is never spent here; it
travels only in the Authorization header and is never printed. Nothing is
written to the runner directory until the bytes match the pinned digest, and
the install is published with one rename of `current`, so a killed attempt
leaves either no runner or the complete pinned one.
"""
import hashlib
import http.client
import io
import json
import os
import secrets
import shutil
import ssl
import subprocess
import sys
import tarfile
import time
import urllib.parse

CONFIG_PATH = "/etc/souls-house-runner/config.json"
RUNNER_DIR = "/opt/souls-house-runner"
STARTED_PATH = "/var/lib/souls-house-runner/fetch-started"
BUNDLE_PATH = "/api/v1/host_runner/birth_bundles/"
# Under Agents::VmBirthPolicy::BIRTH_DEADLINE (45 min); the house fails the
# placement, this only stops retrying.
GIVE_UP_AFTER = 40 * 60
CONNECT_SECONDS = 10
READ_SECONDS = 30
ATTEMPT_SECONDS = 120
MAX_BYTES = 256 * 1024
FILES = {"souls_house_runner.py": 0o755, "backup_proxy.py": 0o644}
MARKER = "bundle.sha256"
GAVE_UP = 3


class Failed(Exception):
    pass


def installed(runner_dir, digest):
    try:
        with open(os.path.join(runner_dir, "current", MARKER)) as handle:
            return handle.read().strip() == digest
    except OSError:
        return False


def first_attempt(path, now):
    """The wall-clock time of the first attempt, recorded once so a reboot
    does not restart the bound."""
    try:
        with open(path) as handle:
            return float(handle.read().strip())
    except (OSError, ValueError):
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        with open(path, "w") as handle:
            handle.write(f"{now}\n")
        return now


def origin_parts(rails_url):
    url = urllib.parse.urlsplit(rails_url)
    if url.scheme != "https" or not url.hostname or url.username or url.password \
            or url.path not in ("", "/") or url.query or url.fragment:
        raise Failed("bad origin")
    return url.hostname, url.port or 443


def fetch(rails_url, runner_id, token, digest, clock=time.monotonic, connection=None):
    """The pinned bundle's bytes. http.client follows no redirects; every
    socket wait is capped by the attempt's remaining time."""
    host, port = origin_parts(rails_url)
    deadline = clock() + ATTEMPT_SECONDS

    def wait(limit):
        remaining = deadline - clock()
        if remaining <= 0:
            raise Failed("attempt deadline")
        return min(limit, remaining)

    if connection is None:
        conn = http.client.HTTPSConnection(host, port, timeout=wait(CONNECT_SECONDS),
                                           context=ssl.create_default_context())
    else:
        conn = connection(host, port, timeout=wait(CONNECT_SECONDS))
    try:
        conn.connect()
        # Kept: http.client drops conn.sock once a response will close, but
        # the response still reads from this socket.
        sock = conn.sock
        sock.settimeout(wait(READ_SECONDS))
        conn.request("GET", BUNDLE_PATH + digest, headers={
            "Authorization": f"Bearer {token}", "X-Runner-Id": runner_id, "Accept": "application/x-xz"})
        response = conn.getresponse()
        if response.status != 200:
            raise Failed(f"status {response.status}")
        data = bytearray()
        # A response that has read its whole body closes the socket.
        while not response.isclosed():
            sock.settimeout(wait(READ_SECONDS))
            chunk = response.read(min(65536, MAX_BYTES + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > MAX_BYTES:
                raise Failed("too large")
        wait(READ_SECONDS)
    finally:
        conn.close()
    if hashlib.sha256(bytes(data)).hexdigest() != digest:
        raise Failed("digest mismatch")
    return bytes(data)


def unpack(data):
    """Exactly FILES, regular files, each compiling (as unpack_runner_bundle)."""
    files = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz") as archive:
            for member in archive.getmembers():
                if member.name not in FILES or not member.isreg() or member.name in files \
                        or member.size > MAX_BYTES * 8:
                    raise Failed("bad member")
                source = archive.extractfile(member).read(member.size + 1)
                if len(source) != member.size:
                    raise Failed("bad member size")
                files[member.name] = source
    except (tarfile.TarError, EOFError, OSError):
        raise Failed("bad archive")
    if set(files) != set(FILES):
        raise Failed("missing member")
    for name, source in files.items():
        try:
            compile(source, name, "exec")
        except (SyntaxError, ValueError):
            raise Failed("does not compile")
    return files


def _write(path, data, mode):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(path, mode)


def _fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _point(directory, name, target):
    """directory/name -> target in one rename, unless it already is."""
    path = os.path.join(directory, name)
    try:
        if os.readlink(path) == target:
            return
    except OSError:
        pass
    temporary = os.path.join(directory, f".{name}.{secrets.token_hex(4)}")
    os.symlink(target, temporary)
    os.replace(temporary, path)
    _fsync_dir(directory)


def install(runner_dir, digest, files):
    """The update_runner layout: versions/<digest>-<rand>/ with the marker,
    entry links through `current`, then `current` itself, last."""
    versions = os.path.join(runner_dir, "versions")
    os.makedirs(versions, mode=0o755, exist_ok=True)
    for name in os.listdir(versions):
        if name.startswith(".stage-"):
            shutil.rmtree(os.path.join(versions, name), ignore_errors=True)
    stage = os.path.join(versions, f".stage-{secrets.token_hex(4)}")
    os.mkdir(stage, 0o755)
    try:
        for name, source in files.items():
            _write(os.path.join(stage, name), source, FILES[name])
        _write(os.path.join(stage, MARKER), (digest + "\n").encode(), 0o644)
        _fsync_dir(stage)
        version = f"{digest}-{secrets.token_hex(4)}"
        os.rename(stage, os.path.join(versions, version))
        _fsync_dir(versions)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    for name in FILES:
        _point(runner_dir, name, os.path.join("current", name))
    _point(runner_dir, "current", os.path.join("versions", version))


def start_runner():
    subprocess.run(["systemctl", "start", "--no-block", "souls-house-runner.service"], check=True)


def main(config_path=CONFIG_PATH, runner_dir=RUNNER_DIR, started_path=STARTED_PATH,
         wall=time.time, start=start_runner, **fetch_options):
    try:
        with open(config_path) as handle:
            config = json.load(handle)
        digest = config["birth_bundle_sha256"]
        if not (isinstance(digest, str) and len(digest) == 64
                and all(c in "0123456789abcdef" for c in digest)):
            raise Failed("bad pinned digest")
        if not installed(runner_dir, digest):
            if wall() - first_attempt(started_path, wall()) > GIVE_UP_AFTER:
                print("runner fetch: gave up after the bound", file=sys.stderr)
                return GAVE_UP
            data = fetch(config["rails_url"], config["runner_id"], config["enrollment_token"], digest,
                         **fetch_options)
            install(runner_dir, digest, unpack(data))
        start()
        return 0
    except Failed as error:
        print(f"runner fetch: {error}", file=sys.stderr)
    except Exception as error:  # Never the message: it could carry a header.
        print(f"runner fetch: {type(error).__name__}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
