"""Transcription providers. Each takes an audio path and returns a dict:
{"text": str, "duration_s": float | None, "usage": dict}.

Keys come from the environment only: ELEVENLABS_API_KEY, GEMINI_API_KEY,
OPENAI_API_KEY. A provider whose key is missing is skipped, not faked.

Prices are deliberately not hard-coded. Put the per-minute or per-token
prices you have checked into prices.json; report.py multiplies them out.
"""
import base64
import json
import mimetypes
import os
import urllib.request
import uuid


class ProviderUnavailable(Exception):
    pass


def _multipart(fields, file_field, path, content_type):
    boundary = uuid.uuid4().hex
    body = b""
    for name, value in fields:
        body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode()
    with open(path, "rb") as f:
        data = f.read()
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; "
             f"filename=\"{os.path.basename(path)}\"\r\nContent-Type: {content_type}\r\n\r\n").encode()
    body += data + f"\r\n--{boundary}--\r\n".encode()
    return body, f"multipart/form-data; boundary={boundary}"


def _post(url, body, headers, timeout=180):
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def _key(name):
    value = os.environ.get(name)
    if not value:
        raise ProviderUnavailable(f"{name} not set")
    return value


def elevenlabs(model_id):
    """Same request shape as lib/eleven_labs_stt.rb, plus word timestamps for duration."""
    def run(path, content_type):
        body, ctype = _multipart(
            [("model_id", model_id), ("tag_audio_events", "false"), ("timestamps_granularity", "word")],
            "file", path, content_type)
        data = _post("https://api.elevenlabs.io/v1/speech-to-text", body,
                     {"xi-api-key": _key("ELEVENLABS_API_KEY"), "Content-Type": ctype})
        words = data.get("words") or []
        duration = max((w.get("end") or 0) for w in words) if words else None
        return {"text": (data.get("text") or "").strip(), "duration_s": duration,
                "usage": {"language": data.get("language_code")}}
    return run


GEMINI_PROMPT = (
    "Transcribe this voice message verbatim. It is one person dictating a chat message, "
    "usually in English, sometimes with names of people, products or code. "
    "Output only the transcript text, with normal punctuation. Keep hesitations like 'um' if spoken. "
    "Do not summarise, translate, or add anything."
)


def gemini(model):
    def run(path, content_type):
        with open(path, "rb") as f:
            audio = base64.b64encode(f.read()).decode()
        payload = {"contents": [{"parts": [
            {"text": GEMINI_PROMPT},
            {"inline_data": {"mime_type": content_type, "data": audio}}]}],
            "generationConfig": {"temperature": 0}}
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={_key('GEMINI_API_KEY')}"
        data = _post(url, json.dumps(payload).encode(), {"Content-Type": "application/json"})
        parts = data["candidates"][0]["content"]["parts"]
        return {"text": "".join(p.get("text", "") for p in parts).strip(), "duration_s": None,
                "usage": data.get("usageMetadata", {})}
    return run


def openai(model):
    def run(path, content_type):
        body, ctype = _multipart([("model", model), ("response_format", "json")], "file", path, content_type)
        data = _post("https://api.openai.com/v1/audio/transcriptions", body,
                     {"Authorization": f"Bearer {_key('OPENAI_API_KEY')}", "Content-Type": ctype})
        return {"text": (data.get("text") or "").strip(), "duration_s": None, "usage": data.get("usage", {})}
    return run


# Name -> factory. Add a line to try a new model; names are what appear in reports.
PROVIDERS = {
    "scribe_v2": elevenlabs("scribe_v2"),
    "gemini-2.5-flash": gemini("gemini-2.5-flash"),
    "gpt-4o-transcribe": openai("gpt-4o-transcribe"),
}


def guess_type(path, fallback="audio/webm"):
    return mimetypes.guess_type(path)[0] or fallback
