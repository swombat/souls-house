"""Bounded, read-only inspection inside an owned resident container."""
import datetime as dt
import hashlib
import json
import os
import re
import stat
import sys

ROOT = "/home/agent/identity/memory"
LAYERS = {
    "journals": ("daily-journals", r"\d{4}-\d{2}-\d{2}"),
    "day_summaries": ("weekly-journals", r"\d{4}-\d{2}-\d{2}"),
    "week_summaries": ("monthly-journals", r"\d{4}-\d{2}"),
    "month_summaries": ("yearly-journals", r"\d{4}"),
}
MAX_FILE, MAX_TOTAL, MAX_ENTRIES, MAX_BODY = 4*1024*1024, 64*1024*1024, 20000, 65536


def directory(path):
    # Pin every ancestor; never follow resident-authored symlinks.
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.strip("/").split("/"):
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_file(fd, name):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    with os.fdopen(os.open(name, flags, dir_fd=fd), "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_FILE:
            raise ValueError("not a bounded regular file")
        data = stream.read(MAX_FILE + 1)
        if len(data) > MAX_FILE:
            raise ValueError("file grew past limit")
        return data


def entries(data):
    starts, offset, fence = [], 0, None
    for raw in data.splitlines(keepends=True):
        line = raw.decode("utf-8", errors="replace")
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if marker:
            run = marker[1]
            if fence is None:
                fence = run
            elif run[0] == fence[0] and len(run) >= len(fence) and not line[marker.end():].strip():
                fence = None
        elif fence is None and re.match(r"^##[ \t]+\S", line):
            starts.append((offset, line.strip()[3:].strip()))
        offset += len(raw)
    if not starts and any(line.strip() and not line.startswith(b"# ") for line in data.splitlines()):
        starts = [(0, "Untitled entry")]
    for index, (start, title) in enumerate(starts):
        yield start, starts[index+1][0] if index+1 < len(starts) else len(data), title


def timestamp(kind, filename, title):
    day = filename[:-3]
    if kind != "journals":
        match = re.search(r"\b(\d{4}-\d{2}(?:-\d{2})?)\b", title)
        if match:
            day = match[1]
    day += "-01" * (2 - day.count("-"))
    date = dt.date.fromisoformat(day)
    clock = re.match(r"(\d{2}):(\d{2})\b", title) if kind == "journals" else None
    hour, minute = (int(clock[1]), int(clock[2])) if clock else (0, 0)
    return dt.datetime.combine(date, dt.time(hour, minute)).isoformat(timespec="microseconds") + "Z"


def scan(mode):
    result = {"status": "measured", "count": 0, "daily_counts": {}, "items": []}
    total, files, item_count = 0, 0, 0
    for kind, (folder, pattern) in LAYERS.items():
        if mode == "overview" and kind != "journals":
            continue
        try:
            fd = directory(ROOT + "/" + folder)
        except FileNotFoundError:
            continue
        try:
            names = []
            with os.scandir(fd) as paths:
                for entry in paths:
                    if re.fullmatch(pattern + r"\.md", entry.name):
                        names.append(entry.name)
                        if len(names) > 10000:
                            raise ValueError("archive file limit")
            for name in sorted(names, reverse=True):
                files += 1
                if files > 10000 or total >= MAX_TOTAL or item_count >= MAX_ENTRIES:
                    result["status"] = "partial"
                    break
                try:
                    data = read_file(fd, name)
                    total += len(data)
                    fingerprint = hashlib.sha256(data).hexdigest()
                    for start, end, title in entries(data):
                        if item_count >= MAX_ENTRIES:
                            result["status"] = "partial"
                            break
                        item_count += 1
                        try:
                            occurred = timestamp(kind, name, title)
                        except ValueError:
                            occurred = timestamp(kind, name, "")
                        if kind == "journals":
                            result["count"] += 1
                            day = name[:-3]
                            result["daily_counts"][day] = result["daily_counts"].get(day, 0) + 1
                        if mode == "catalog":
                            result["items"].append({"id": f"{folder}/{name}:{start:012d}", "kind": kind,
                                "occurred_at": occurred, "timestamp_basis": "journal heading" if kind == "journals" else "summary period",
                                "title": title[:500], "path": f"{folder}/{name}", "start": start, "end": end,
                                "fingerprint": fingerprint})
                except (OSError, ValueError):
                    result["status"] = "partial"
        finally:
            os.close(fd)
    if mode == "overview":
        del result["items"]
    return result


def bodies(selections):
    if not isinstance(selections, list) or len(selections) > 50:
        raise ValueError("invalid selection")
    result = {}
    for item in selections:
        parts = item["path"].split("/")
        if len(parts) != 2 or not any(parts[0] == folder and re.fullmatch(pattern + r"\.md", parts[1]) for folder, pattern in LAYERS.values()):
            raise ValueError("invalid path")
        try:
            fd = directory(ROOT + "/" + parts[0])
            try:
                data = read_file(fd, parts[1])
            finally:
                os.close(fd)
            if hashlib.sha256(data).hexdigest() != item["fingerprint"]:
                result[item["id"]] = {"body_status": "changed"}
                continue
            start, end = item["start"], item["end"]
            if not (0 <= start < end <= len(data)):
                raise ValueError("invalid range")
            result[item["id"]] = {"body": data[start:min(end, start + MAX_BODY)].decode("utf-8", errors="replace"),
                                  "body_status": "truncated" if end-start > MAX_BODY else "complete"}
        except (OSError, ValueError):
            result[item["id"]] = {"body_status": "unavailable"}
    return result


request = json.load(sys.stdin)
mode = request["mode"]
if mode in ("overview", "catalog"):
    response = scan(mode)
elif mode == "bodies":
    response = bodies(request["items"])
else:
    raise ValueError("invalid mode")
print(json.dumps(response))
