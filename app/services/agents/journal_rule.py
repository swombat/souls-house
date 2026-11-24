# The resident's journal: where it is and what one entry is. One rule, read by
# the card's count (Agents::JournalEntryStats::SCRIPT and the runner's
# byte-for-byte copy, HOME_STATS_SCRIPT) and by the Memories tab
# (memory_archive.py). The home declares the place in its resident-home.json:
#   "journal": {"path": "<folder or .md file inside the home>"}   that place
#   "journal": false                                              not shared
#   no "journal" key        an admin's chosen file if there is one, else
#                           memory/daily-journals (a missing one is empty)
# A .md file's entries are its "## " headings outside fences (a file with none
# but some text besides a "# " title is one untitled entry). In a folder,
# YYYY-MM-DD.md is read that way; inside a YYYY-MM-DD/ folder each non-empty
# .md is exactly one entry, whatever headings it holds. Dotfiles and README.md are skipped; nothing else is read. Every
# step is opened from the home down without following links, so a link swapped
# in after any check is refused at open, not followed.
import json, os, re, stat, time

HOME = "/home/agent/identity"
DEFAULT_JOURNAL = "memory/daily-journals"
JOURNAL_PATH_MAX = 200
MANIFEST_MAX = 64 * 1024
DIRECTORY_NAMES_MAX = 20000
DAY = r"\d{4}-\d{2}-\d{2}"
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK


class NotShared(Exception):
    pass


def valid_journal_path(path):
    # Plain relative segments only: no "..", no "/" at either end, no links.
    if not isinstance(path, str) or not path or len(path) > JOURNAL_PATH_MAX:
        return False
    return all(re.fullmatch(r"[A-Za-z0-9_.-]+", part) and part.strip(".") for part in path.split("/"))


def read_file(directory, name, limit):
    with os.fdopen(os.open(name, FILE_FLAGS, dir_fd=directory), "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError("not a bounded regular file")
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("file grew past its limit")
    return data


def journal_place(home, fallback=None):
    # (path, declared) for the journal, relative to the home. declared is False
    # only for the default, whose absence is an empty journal; a declared place
    # that is missing is an error. Raises NotShared for "journal": false.
    if fallback is not None and not (valid_journal_path(fallback) and fallback.startswith("memory/")
                                     and fallback.endswith(".md")):
        raise ValueError("invalid journal source")
    try:
        manifest = json.loads(read_file(home, "resident-home.json", MANIFEST_MAX))
    except FileNotFoundError:
        manifest = {}
    if not isinstance(manifest, dict):
        raise ValueError("invalid home manifest")
    if "journal" not in manifest:
        return (fallback, True) if fallback is not None else (DEFAULT_JOURNAL, False)
    journal = manifest["journal"]
    if journal is False:
        raise NotShared()
    if isinstance(journal, dict) and set(journal) == {"path"} and valid_journal_path(journal["path"]):
        return journal["path"], True
    raise ValueError("invalid journal declaration")


def _names(directory):
    names = []
    with os.scandir(directory) as found:
        for entry in found:
            names.append((entry.name, entry.is_file(follow_symlinks=False), entry.is_dir(follow_symlinks=False)))
            if len(names) > DIRECTORY_NAMES_MAX:
                raise ValueError("too many files in one journal folder")
    return sorted(names, reverse=True)


def _document(directory, name, path, day, whole, limit):
    try:
        data = read_file(directory, name, limit)
    except (OSError, ValueError):
        data = None
    return {"path": path, "day": day, "whole": whole, "data": data}


def documents(home, path, limit):
    # Every file the rule reads, newest first, as {"path", "day", "whole",
    # "data"}: whole means the file is one entry, else its headings are; data is
    # None for a file that could not be read within the limit. A place that
    # names nothing raises FileNotFoundError; a link anywhere raises OSError.
    parts = path.split("/")
    parent = os.dup(home)
    try:
        for part in parts[:-1]:
            inner = os.open(part, DIRECTORY_FLAGS, dir_fd=parent)
            os.close(parent)
            parent = inner
        try:
            folder = os.open(parts[-1], DIRECTORY_FLAGS, dir_fd=parent)
        except NotADirectoryError:
            if not parts[-1].endswith(".md"):
                raise ValueError("a journal file must be Markdown")
            # One file has no dates in its name: an entry is dated by its
            # heading, else by the day the file last changed.
            modified = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False).st_mtime
            data = read_file(parent, parts[-1], limit)
            yield {"path": path, "day": time.strftime("%Y-%m-%d", time.gmtime(modified)), "modified": True,
                   "whole": False, "data": data}
            return
    finally:
        os.close(parent)
    try:
        for name, is_file, is_dir in _names(folder):
            if is_file and re.fullmatch(DAY + r"\.md", name):
                yield _document(folder, name, path + "/" + name, name[:-3], False, limit)
            elif is_dir and re.fullmatch(DAY, name):
                day = os.open(name, DIRECTORY_FLAGS, dir_fd=folder)
                try:
                    for inner, inner_is_file, _ in _names(day):
                        if not inner_is_file or inner.startswith(".") or inner == "README.md" or not inner.endswith(".md"):
                            continue
                        document = _document(day, inner, path + "/" + name + "/" + inner, name, True, limit)
                        if document["data"] is None or document["data"].strip():
                            yield document
                finally:
                    os.close(day)
    finally:
        os.close(folder)


def headings(data):
    # (offset, title) of each "## " heading outside fenced blocks.
    found, offset, fence = [], 0, None
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
            found.append((offset, line.strip()[3:].strip()))
        offset += len(raw)
    return found


def entries(document):
    # (start, end, title) of each entry in one document. A whole file is one
    # entry, titled by its first heading when it has one; "" is untitled.
    data = document["data"]
    found = headings(data)
    if document["whole"]:
        return [(0, len(data), found[0][1] if found else "")]
    if not found and any(line.strip() and not line.startswith(b"# ") for line in data.splitlines()):
        return [(0, len(data), "")]
    return [(start, found[index + 1][0] if index + 1 < len(found) else len(data), title)
            for index, (start, title) in enumerate(found)]
