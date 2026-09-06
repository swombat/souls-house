"""Best-effort command redaction; never execute a command to describe it."""
import json
import os
from pathlib import Path
import re
import shlex
import urllib.parse

POLICY = json.loads(Path(__file__).with_name("command_preview_policy.json").read_text())
SENSITIVE = re.compile(POLICY["sensitive_name"], re.I)
PATTERNS = [re.compile(pattern) for pattern in POLICY["secret_patterns"]]
REDACTED = "[REDACTED]"
HIDDEN = "Command [payload hidden]"


def preview(command, secrets=()):
    if not isinstance(command, str) or len(command.encode(errors="replace")) > 16384:
        return HIDDEN
    # Known runtime credentials provide an additional guard, not a guarantee
    # that all secrets (e.g. values loaded from a resident's files) are known.
    for secret in sorted(set(secrets), key=len, reverse=True):
        if isinstance(secret, str) and len(secret) >= 8:
            command = command.replace(secret, "__REDACTED__")
    try:
        for _ in range(3):
            words = shlex.split(command)
            if len(words) == 3 and os.path.basename(words[0]) in POLICY["shells"] and words[1] in ("-c", "-lc"):
                command = words[2]
            else:
                break
        # Opaque shell expansion and multiline payloads are not safely
        # interpretable with a display-only lexer.
        if any(marker in command for marker in ("`", "$(", "<(", ">(")):
            return HIDDEN
        if "<<" in command:
            return preview(command.split("<<", 1)[0], secrets) + " << [payload hidden]"
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|<>()\n")
        lexer.whitespace = " \t\r"
        lexer.whitespace_split = True
        lexer.commenters = "#"
        words = list(lexer)
    except ValueError:
        return HIDDEN
    result = []
    hide_next = False
    executable = None
    positional_seen = False
    for word in words:
        if word and not word.strip("\n"):
            word = ";"
        if word in (";", "&&", "||", "|", "&"):
            result.append(word)
            executable, positional_seen, hide_next = None, False, False
            continue
        if hide_next:
            result.append(REDACTED)
            hide_next = False
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", word):
            result.append(word.split("=", 1)[0] + "=" + REDACTED)
            continue
        if executable is None:
            executable = os.path.basename(word)
        elif executable in ("sed", "awk") and not word.startswith("-") and not positional_seen:
            result.append(REDACTED)
            positional_seen = True
            continue
        name, equals, _value = word.partition("=")
        if (executable in ("curl", "wget") and re.match(r"^-[HudFb].+", word)) or (
            executable in POLICY["script_commands"] and re.match(r"^-[ce].+", word)):
            result.append(word[:2] + REDACTED)
            continue
        private_flag = name in POLICY["private_value_flags"] or (
            name.startswith("-") and SENSITIVE.search(name))
        script_flag = executable in POLICY["script_commands"] + POLICY["shells"] + ["sed", "awk"] and name in POLICY["script_flags"] + ["-lc"]
        if private_flag or script_flag:
            if private_flag and name not in POLICY["private_value_flags"]:
                name = "--[sensitive-option]"
            result.append(name + "=" + REDACTED if equals else name)
            hide_next = not equals
            continue
        if word == "runner" and executable in ("rails", "bundle"):
            result.append(word)
            hide_next = True
            continue
        if word.lower() in ("bearer", "basic"):
            result.append(word)
            hide_next = True
            continue
        result.append(scrub(word))
    rendered = " ".join(quote(word) for word in result)
    return (rendered.encode()[:1000].decode(errors="ignore") + (" …" if len(rendered.encode()) > 1000 else "")) or HIDDEN


def scrub(word):
    if "\n" in word or "\r" in word or re.search(r"[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]", word):
        return REDACTED
    if "__REDACTED__" in word:
        word = word.replace("__REDACTED__", REDACTED)
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", word):
        try:
            url = urllib.parse.urlsplit(word)
            host = url.netloc.rsplit("@", 1)[-1]
            word = urllib.parse.urlunsplit((url.scheme, host, url.path,
                REDACTED if url.query else "", REDACTED if url.fragment else ""))
        except ValueError:
            return REDACTED
    if re.search(r"(?i)(authorization|cookie)\s*:", word):
        return REDACTED
    if "=" in word or ":" in word:
        key = re.split("[=:]", word, 1)[0]
        if SENSITIVE.search(key):
            return key + "=" + REDACTED
    for pattern in PATTERNS:
        word = pattern.sub(REDACTED, word)
    return word


def quote(word):
    if word in (";", "&&", "||", "|", "&", ">", ">>", "<", REDACTED):
        return word
    if re.search(r"\s|['\"\\]", word):
        return '"' + word.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return word
