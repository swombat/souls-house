"""Read-only manifest validator prototype. No runtime hook or probes."""

from dataclasses import dataclass
import os
import re
import stat

import yaml

MAX_BYTES = 16_384
MAX_ENTRIES = 32
MAX_TOKENS = 2048
MAX_DEPTH = 32
REVIEWED = {("apt", "ffmpeg"), ("pip", "numpy"), ("pip", "scipy")}


class InvalidManifest(ValueError):
    """Deliberately generic: do not leak private reasons or parser excerpts."""


def read_manifest(path: str) -> bytes:
    """Read at most MAX_BYTES+1 from a regular file, without following symlinks.

    FileNotFoundError is preserved for the caller's distinct absent-file state.
    Other read failures remain invalid, never an empty manifest. Linux-only
    flags prevent blocking on FIFOs and following the final path symlink;
    parent directories must belong to the trusted runtime configuration.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise InvalidManifest("Invalid manifest")
            raw = stream.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                raise InvalidManifest("Invalid manifest")
            return raw
    except FileNotFoundError:
        raise
    except (OSError, InvalidManifest):
        raise InvalidManifest("Invalid manifest") from None


class UniqueSafeLoader(yaml.SafeLoader):
    pass


def _mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if not isinstance(key, str) or key in result:
            raise InvalidManifest("Invalid manifest")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueSafeLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping
)


@dataclass(frozen=True)
class Declaration:
    channel: str
    name: str
    supported: bool


def validate(raw: bytes) -> tuple[Declaration, ...]:
    """Validate bounded YAML, stripping reasons before returning declarations.

    Missing-file handling belongs to the future caller. Empty/malformed files
    are invalid, not evidence of an empty manifest.
    """
    if not isinstance(raw, bytes) or len(raw) > MAX_BYTES:
        raise InvalidManifest("Invalid manifest")
    try:
        text = raw.decode("utf-8")
        # Reject aliases entirely, preventing recursive graphs/expansion.
        for index, token in enumerate(yaml.scan(text)):
            if index >= MAX_TOKENS:
                raise InvalidManifest("Invalid manifest")
            if isinstance(token, (yaml.tokens.AliasToken, yaml.tokens.AnchorToken)):
                raise InvalidManifest("Invalid manifest")
        # Reject excessive nesting before constructing Python objects. A byte
        # cap alone does not bound recursion depth in compact flow-style YAML.
        depth = 0
        for event in yaml.parse(text):
            if isinstance(event, (yaml.events.MappingStartEvent, yaml.events.SequenceStartEvent)):
                depth += 1
                if depth > MAX_DEPTH:
                    raise InvalidManifest("Invalid manifest")
            elif isinstance(event, (yaml.events.MappingEndEvent, yaml.events.SequenceEndEvent)):
                depth -= 1
        data = yaml.load(text, Loader=UniqueSafeLoader)
        if not isinstance(data, dict) or not data or set(data) - {"apt", "pip"}:
            raise InvalidManifest("Invalid manifest")
        declarations = []
        seen = set()
        for channel, entries in data.items():
            if not isinstance(entries, list):
                raise InvalidManifest("Invalid manifest")
            if len(declarations) + len(entries) > MAX_ENTRIES:
                raise InvalidManifest("Invalid manifest")
            for entry in entries:
                if not isinstance(entry, dict) or set(entry) != {"name", "reason"}:
                    raise InvalidManifest("Invalid manifest")
                name, reason = entry["name"], entry["reason"]
                # PEP 503 distribution names are case-insensitive and collapse
                # runs of '.', '_' and '-'. Apt names stay literal.
                if channel == "pip" and isinstance(name, str):
                    name = re.sub(r"[-_.]+", "-", name.lower())
                if (
                    not isinstance(name, str)
                    or not name
                    or len(name) > 128
                    or name[0] not in "abcdefghijklmnopqrstuvwxyz0123456789"
                    or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-._+" for c in name)
                    or not isinstance(reason, str)
                    or not reason.strip()
                    or len(reason) > 2048
                ):
                    raise InvalidManifest("Invalid manifest")
                key = (channel, name)
                if key in seen:
                    raise InvalidManifest("Invalid manifest")
                seen.add(key)
                declarations.append(Declaration(channel, name, key in REVIEWED))
        return tuple(declarations)
    except (yaml.YAMLError, UnicodeError, RecursionError, InvalidManifest):
        raise InvalidManifest("Invalid manifest") from None
