#!/usr/bin/env python3
"""Merge one resident's old subscription Chaos store into their main store.

Run on the Docker host holding the resident (house host or resident VM), as a
user in the docker group, for one resident at a time, with that resident's
container STOPPED and kept stopped (that is what keeps every writer of both
stores still):

    ops/chaos-home/merge_oauth_store.py <agent uuid> [--dry-run]

1. Refuses if the container is running, or its Chaos home is not backed by
   an existing plain local Docker volume. Never creates a volume.
2. Reads `.chaos/config.toml` and `.chaos/oauth-runtime/config.toml` from the
   resident's chaos-home volume and takes only the database names (and checks
   both name the same server). No connection string is printed or passed on.
3. Runs oauth_store_merge.sql in the main database, as the server's superuser
   over its local socket, as one transaction (--dry-run: every check and the
   whole copy, then ROLLBACK).
4. Only if the merge marker for exactly this source and destination exists,
   moves oauth-runtime/config.toml aside to config.toml.merged-into-main, in
   the volume, so the shim lets subscription runs use the main home. A retry
   after a crash between commit and move finds the marker and does only the
   move.

The source database is kept. Start the resident afterwards and check that one
of its subscription threads resumes.

If migrations differ, back up the source first. In a maintenance container
using the resident's Chaos binary, home mount and database environment, run
`CHAOS_HOME=/home/agent/.chaos/oauth-runtime chaos hooks list` to migrate the
source. Keep the normal resident stopped; close the maintenance container
before repeating the dry run. The merge script does not do this for you.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path
from urllib.parse import urlparse

MERGE_SQL = Path(__file__).with_name("oauth_store_merge.sql")
MOVED_NAME = "config.toml.merged-into-main"
CHAOS_HOME = "/home/agent/.chaos"
MISSING_FILE = 44  # reserved exit status of the read helper (not a Docker error)
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
DBNAME = re.compile(r"^[a-z0-9_]+$")


class Refused(Exception):
    pass


def docker(*args, input=None, check=True):
    result = subprocess.run(["docker", *args], input=input, capture_output=True, text=True, timeout=3600)
    if check and result.returncode:
        # stderr from psql/docker can carry statement text but never a URL we built.
        raise Refused(f"docker {args[0]} failed: {result.stderr.strip()[-2000:]}")
    return result


def store_location(bootstrap_text, container_env):
    """(server, dbname) from a Chaos bootstrap config, or None if it names no store."""
    url = tomllib.loads(bootstrap_text).get("storage_url")
    if not url:
        return None
    if url.startswith("env:"):
        url = container_env.get(url[4:], "")
    parsed = urlparse(url)
    if parsed.scheme not in ("postgres", "postgresql"):
        raise Refused("store is not PostgreSQL; this merge only joins two PostgreSQL stores")
    name = parsed.path.lstrip("/")
    if not DBNAME.match(name):
        raise Refused("store database name is not a plain identifier")
    return (parsed.hostname, parsed.port or 5432), name


class Merge:
    def __init__(self, agent, pg_container="souls-house-postgres", run=docker, out=print):
        if not UUID.match(agent):
            raise Refused("agent must be the resident's uuid")
        self.container = f"hk-agent-{agent}"
        self.pg = pg_container
        self.run = run
        self.out = out

    def inspect(self):
        data = json.loads(self.run("inspect", self.container).stdout)[0]
        if data["State"]["Running"]:
            raise Refused(f"{self.container} is running; stop it first")
        mounts = [mount for mount in data.get("Mounts", []) if mount["Destination"] == CHAOS_HOME]
        if len(mounts) != 1 or mounts[0]["Type"] != "volume" or not mounts[0].get("Name"):
            raise Refused(f"{self.container} needs exactly one named volume mounted at {CHAOS_HOME}")
        name = mounts[0]["Name"]
        result = self.run("volume", "inspect", name, check=False)
        if result.returncode:
            raise Refused("cannot inspect the resident's Chaos home volume; no volume was created")
        volume, = json.loads(result.stdout)
        mountpoint = volume.get("Mountpoint", "")
        if (volume.get("Name") != name or volume.get("Driver") != "local" or volume.get("Options")
                or mountpoint != mounts[0].get("Source") or not Path(mountpoint).is_absolute()
                or "," in mountpoint):
            raise Refused("the resident's Chaos home is not a plain local volume with a usable mountpoint")
        env = dict(item.split("=", 1) for item in data["Config"].get("Env") or [] if "=" in item)
        return data["Image"], env, mountpoint

    def volume_cmd(self, image, mountpoint, *command, writable=False):
        # A named-volume mount can auto-create a missing volume even after
        # inspection. An explicit bind mount instead refuses a missing path.
        mount = f"type=bind,source={mountpoint},target=/c" + ("" if writable else ",readonly")
        return self.run("run", "--rm", "--network", "none", "--user", "0", "--mount", mount,
                        "--entrypoint", command[0], image, *command[1:], check=False)

    def read(self, image, mountpoint, path):
        result = self.volume_cmd(
            image, mountpoint, "sh", "-c",
            f'if [ ! -e "$1" ] && [ ! -L "$1" ]; then exit {MISSING_FILE}; fi; exec cat "$1"',
            "read-config", f"/c/{path}",
        )
        if result.returncode == MISSING_FILE:
            return None
        if result.returncode:
            raise Refused(f"could not read {path} from the resident's Chaos home")
        return result.stdout

    def psql(self, db, sql, src=None):
        user = self.run("exec", self.pg, "printenv", "POSTGRES_USER").stdout.strip()
        args = ["exec", "-i", self.pg, "psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1",
                "-U", user, "-d", db]
        if src:
            args += ["-v", f"src={src}"]
        return self.run(*args, "-f", "-", input=sql)

    def marker(self, src, dst):
        sql = (f"SELECT processes || ' ' || journal_entries FROM house_oauth_store_merges "
               f"WHERE source_db = '{src}' AND dest_db = current_database() "
               f"AND source_oid = (SELECT oid FROM pg_database WHERE datname = '{src}') "
               f"AND dest_oid = (SELECT oid FROM pg_database WHERE datname = current_database()) "
               f"AND to_regclass('house_oauth_store_merges') IS NOT NULL;")
        guard = "SELECT to_regclass('house_oauth_store_merges') IS NOT NULL;"
        if self.psql(dst, guard).stdout.strip() != "t":
            return None
        return self.psql(dst, sql).stdout.strip() or None

    def __call__(self, dry_run=False):
        image, env, mountpoint = self.inspect()
        oauth_text = self.read(image, mountpoint, "oauth-runtime/config.toml")
        if oauth_text is None or store_location(oauth_text, env) is None:
            moved = self.read(image, mountpoint, f"oauth-runtime/{MOVED_NAME}") is not None
            self.out("nothing to merge: " + ("already merged and moved aside" if moved
                                             else "oauth-runtime names no store of its own"))
            return 0
        main_text = self.read(image, mountpoint, "config.toml")
        if main_text is None:
            raise Refused("the main home has no config.toml")
        (src_server, src), main = store_location(oauth_text, env), store_location(main_text, env)
        if main is None:
            raise Refused("the main home names no store")
        dst_server, dst = main
        if src_server != dst_server:
            raise Refused("the two stores are on different servers; this merge needs one server")
        self.out(f"source {src} -> destination {dst}")
        if self.marker(src, dst) is None:
            sql = MERGE_SQL.read_text()
            if dry_run:
                result = self.psql(dst, "BEGIN;\n" + sql + "\nROLLBACK;\n", src=src)
                self.out(result.stderr.strip() or "dry run completed")
                self.out("dry run: rolled back; nothing changed")
                return 0
            result = self.psql(dst, "BEGIN;\n" + sql + "\nCOMMIT;\n", src=src)
            self.out(result.stderr.strip())
        elif dry_run:
            self.out("dry run: already merged; would only move the config aside")
            return 0
        counts = self.marker(src, dst)
        if counts is None:
            raise Refused("no merge marker for this pair after the merge; config left in place")
        moved = self.volume_cmd(image, mountpoint, "mv", "/c/oauth-runtime/config.toml",
                                f"/c/oauth-runtime/{MOVED_NAME}", writable=True)
        if moved.returncode:
            raise Refused("merged, but moving oauth-runtime/config.toml aside failed; rerun to retry the move")
        processes, journal = counts.split()
        self.out(f"merged: {processes} processes, {journal} journal rows; "
                 f"oauth-runtime/config.toml moved to {MOVED_NAME}; source database kept")
        return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("agent")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--pg-container", default=os.environ.get("SOULS_HOUSE_PG_CONTAINER", "souls-house-postgres"))
    args = parser.parse_args(argv)
    try:
        return Merge(args.agent, pg_container=args.pg_container)(dry_run=args.dry_run)
    except Refused as refused:
        print(f"refused: {refused}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
