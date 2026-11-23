# Bounded, read-only inspection inside an owned resident container. Runs after
# journal_rule.py (Agents::MemoryArchive sends the two as one script): the
# journals layer is exactly what that rule reads, the same entries the card
# counts. The summary layers stay where they always were, under memory/.
import contextlib
import datetime as dt
import hashlib
import sys
import time

SUMMARIES = {
    "day_summaries": ("memory/weekly-journals", r"\d{4}-\d{2}-\d{2}"),
    "week_summaries": ("memory/monthly-journals", r"\d{4}-\d{2}"),
    "month_summaries": ("memory/yearly-journals", r"\d{4}"),
}
MAX_FILE, MAX_TOTAL, MAX_ENTRIES, MAX_BODY, MAX_FILES = 4*1024*1024, 64*1024*1024, 20000, 65536, 10000


def directory(home, path):
    # Walk down from the home; never follow resident-authored symlinks.
    fd = os.dup(home)
    try:
        for part in path.split("/"):
            next_fd = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def summary_documents(home, folder, pattern):
    try:
        fd = directory(home, folder)
    except FileNotFoundError:
        return
    try:
        names = []
        with os.scandir(fd) as paths:
            for entry in paths:
                if re.fullmatch(pattern + r"\.md", entry.name):
                    names.append(entry.name)
                    if len(names) > MAX_FILES:
                        raise ValueError("archive file limit")
        for name in sorted(names, reverse=True):
            try:
                data = read_file(fd, name, MAX_FILE)
            except (OSError, ValueError):
                data = None
            yield {"path": folder + "/" + name, "day": name[:-3], "whole": False, "data": data}
    finally:
        os.close(fd)


def timestamp(kind, document, title):
    day = document["day"]
    if kind != "journals" or document.get("modified"):
        match = re.search(r"\b(\d{4}-\d{2}(?:-\d{2})?)\b", title)
        if match:
            day = match[1]
    day += "-01" * (2 - day.count("-"))
    date = dt.date.fromisoformat(day)
    clock = re.search(r"\b(\d{2}):(\d{2})\b", title) if document.get("modified") else (
        re.match(r"(\d{2}):(\d{2})\b", title) if kind == "journals" else None)
    hour, minute = (int(clock[1]), int(clock[2])) if clock else (0, 0)
    return dt.datetime.combine(date, dt.time(hour, minute)).isoformat(timespec="microseconds") + "Z"


def scan(mode, fallback):
    result = {"status": "measured", "count": 0, "daily_counts": {}, "items": []}
    budget = {"files": 0, "total": 0, "items": 0}
    home = os.open(HOME, DIRECTORY_FLAGS)
    try:
        try:
            place, declared = journal_place(home, fallback)
        except NotShared:
            # Not shared closes the count and every journal layer.
            result.update(status="not_shared", count=None)
            return result
        layers = [("journals", lambda: documents(home, place, MAX_FILE))]
        if mode == "catalog":
            layers += [(kind, lambda folder=folder, pattern=pattern: summary_documents(home, folder, pattern))
                       for kind, (folder, pattern) in SUMMARIES.items()]
        for kind, found in layers:
            try:
                with contextlib.closing(found()) as stream:
                    for document in stream:
                        if not read_document(kind, document, mode, result, budget):
                            break
            except FileNotFoundError:
                if kind == "journals" and declared:
                    raise
    finally:
        os.close(home)
    if mode == "overview":
        del result["items"]
    return result


def read_document(kind, document, mode, result, budget):
    budget["files"] += 1
    if budget["files"] > MAX_FILES or budget["total"] >= MAX_TOTAL or budget["items"] >= MAX_ENTRIES:
        result["status"] = "partial"
        return False
    data = document["data"]
    if data is None:
        result["status"] = "partial"
        return True
    budget["total"] += len(data)
    fingerprint = hashlib.sha256(data).hexdigest()
    for start, end, title in entries(document):
        if budget["items"] >= MAX_ENTRIES:
            result["status"] = "partial"
            return False
        budget["items"] += 1
        if kind == "journals":
            result["count"] += 1
        if not title:
            title = document["path"].rsplit("/", 1)[-1][:-3] if document["whole"] else "Untitled entry"
        try:
            occurred = timestamp(kind, document, title)
        except ValueError:
            try:
                occurred = timestamp(kind, document, "")
            except ValueError:
                result["status"] = "partial"
                continue
        if kind == "journals":
            day = occurred[:10]
            result["daily_counts"][day] = result["daily_counts"].get(day, 0) + 1
        if mode == "catalog":
            result["items"].append({"id": f"{document['path']}:{start:012d}", "kind": kind,
                "occurred_at": occurred, "timestamp_basis": "journal heading" if kind == "journals" else "summary period",
                "title": title[:500], "path": document["path"], "start": start, "end": end,
                "fingerprint": fingerprint})
    return True


def journal_file(place, path):
    # True when path names a file the rule reads in this journal.
    if path == place:
        return path.endswith(".md")
    if not path.startswith(place + "/"):
        return False
    rest = path[len(place) + 1:].split("/")
    if len(rest) == 1:
        return bool(re.fullmatch(DAY + r"\.md", rest[0]))
    return (len(rest) == 2 and bool(re.fullmatch(DAY, rest[0])) and rest[1].endswith(".md")
            and not rest[1].startswith(".") and rest[1] != "README.md")


def bodies(selections, fallback):
    if not isinstance(selections, list) or len(selections) > 50:
        raise ValueError("invalid selection")
    home = os.open(HOME, DIRECTORY_FLAGS)
    try:
        try:
            place = journal_place(home, fallback)[0]
        except NotShared:
            # Not shared closes every journal layer: nothing is read.
            return {item["id"]: {"body_status": "unavailable"} for item in selections}
        result = {}
        for item in selections:
            path = item["path"]
            folder, _, name = path.rpartition("/")
            summary = any(folder == layer and re.fullmatch(pattern + r"\.md", name) for layer, pattern in SUMMARIES.values())
            if not valid_journal_path(path) or not (summary or journal_file(place, path)):
                raise ValueError("invalid path")
            try:
                fd = directory(home, folder) if folder else os.dup(home)
                try:
                    data = read_file(fd, name, MAX_FILE)
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
    finally:
        os.close(home)


request = json.load(sys.stdin)
mode = request["mode"]
fallback = request.get("journal_source")
if mode in ("overview", "catalog"):
    response = scan(mode, fallback)
elif mode == "bodies":
    response = bodies(request["items"], fallback)
else:
    raise ValueError("invalid mode")
print(json.dumps(response))
