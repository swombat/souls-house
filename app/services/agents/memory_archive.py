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


# A heading's date and clock. `\b` cannot be trusted here: in an ISO
# heading like "2026-11-23T21:01:27.228101+00:00" the T is a word
# character, so there is no boundary on either side of it (Reed, #1113).
DATE_IN_TITLE = re.compile(r"(?<![\d-])(\d{4}-\d{2}(?:-\d{2})?)(?![\d-])")
LEADING_CLOCK = re.compile(r"(?:\d{4}-\d{2}-\d{2}[T ])?(\d{2}):(\d{2})(?::(\d{2}))?(?!\d)")
CLOCK_IN_TITLE = re.compile(r"(?<![:\d+-])(\d{2}):(\d{2})(?::(\d{2}))?(?!\d)")


def timestamp(kind, document, title):
    day = document["day"]
    if kind != "journals" or document.get("modified"):
        match = DATE_IN_TITLE.search(title)
        if match:
            day = match[1]
    day += "-01" * (2 - day.count("-"))
    try:
        date = dt.date.fromisoformat(day)
    except ValueError:
        date = dt.date.fromisoformat(document["day"] + "-01" * (2 - document["day"].count("-")))
    clock = CLOCK_IN_TITLE.search(title) if document.get("modified") else (
        LEADING_CLOCK.match(title) if kind == "journals" else None)
    try:
        moment = dt.time(*(int(part) for part in clock.groups(default="0"))) if clock else dt.time()
    except ValueError:
        moment = dt.time()
    return dt.datetime.combine(date, moment).isoformat(timespec="microseconds") + "Z"


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


def entry_file_name(name):
    # Any name documents() reads inside a day folder: one segment, no leading
    # dot (so never ".."), Markdown, not the guide. Opened with no-follow.
    return (isinstance(name, str) and "/" not in name and "\0" not in name and not name.startswith(".")
            and name.endswith(".md") and name != "README.md" and len(name.encode("utf-8", "surrogateescape")) <= 255)


def eligible(place, path):
    # True when path names a file the scan reads: a summary-layer file, or one
    # of the declared journal's files, matched exactly as documents() finds them.
    if not isinstance(path, str):
        return False
    folder, _, name = path.rpartition("/")
    if valid_journal_path(path) and any(folder == layer and re.fullmatch(pattern + r"\.md", name)
                                        for layer, pattern in SUMMARIES.values()):
        return True
    if path == place:
        return path.endswith(".md")
    if not path.startswith(place + "/"):
        return False
    rest = path[len(place) + 1:].split("/", 1)
    if len(rest) == 1:
        return bool(re.fullmatch(DAY + r"\.md", rest[0]))
    return bool(re.fullmatch(DAY, rest[0])) and entry_file_name(rest[1])


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
            # A refusal is the item's alone: one odd selection never costs the
            # rest of the page its bodies.
            try:
                path = item["path"]
                if not eligible(place, path):
                    raise ValueError("not a file the journal rule reads")
                folder, _, name = path.rpartition("/")
                fd = directory(home, folder) if folder else os.dup(home)
                try:
                    data = read_file(fd, name, MAX_FILE)
                finally:
                    os.close(fd)
                if hashlib.sha256(data).hexdigest() != item["fingerprint"]:
                    result[item["id"]] = {"body_status": "changed"}
                    continue
                start, end = item["start"], item["end"]
                if not (isinstance(start, int) and isinstance(end, int) and 0 <= start < end <= len(data)):
                    raise ValueError("invalid range")
                result[item["id"]] = {"body": data[start:min(end, start + MAX_BODY)].decode("utf-8", errors="replace"),
                                      "body_status": "truncated" if end-start > MAX_BODY else "complete"}
            except (OSError, ValueError, KeyError, TypeError):
                result[str(item.get("id")) if isinstance(item, dict) else "invalid"] = {"body_status": "unavailable"}
        return result
    finally:
        os.close(home)


def declaration(fallback):
    # The current declaration alone, cheap and never cached: the house checks
    # it before serving a cached overview or catalog, so "not shared" takes
    # effect at once.
    home = os.open(HOME, DIRECTORY_FLAGS)
    try:
        place, declared = journal_place(home, fallback)
        return {"status": "declared", "place": place, "declared": bool(declared)}
    except NotShared:
        return {"status": "not_shared"}
    finally:
        os.close(home)


request = json.load(sys.stdin)
mode = request["mode"]
fallback = request.get("journal_source")
if mode == "declaration":
    response = declaration(fallback)
elif mode in ("overview", "catalog"):
    response = scan(mode, fallback)
elif mode == "bodies":
    response = bodies(request["items"], fallback)
else:
    raise ValueError("invalid mode")
print(json.dumps(response))
