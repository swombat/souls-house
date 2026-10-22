"""Download and verify the public pinned checkpoint at build time only."""
import hashlib
import json
import os
from pathlib import Path
import sys
from urllib.request import urlopen

os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["HF_HUB_OFFLINE"] = "1"  # Downloader uses explicit public HTTPS, not a Hub client.
os.environ["PYANNOTE_METRICS_ENABLED"] = "0"
os.environ["DO_NOT_TRACK"] = "1"

REVISION = "837717ddb9ff5507820346191109dc79c958d614"
REPOSITORY = "pyannote/wespeaker-voxceleb-resnet34-LM"


def download(destination):
    name = "pytorch_model.bin"
    expected = json.loads(Path(__file__).with_name("model-sha256.json").read_text())[name]
    # No Hub client, token discovery or resident credentials.
    with urlopen(f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{name}", timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError("Model integrity check failed")
    Path(destination).mkdir(parents=True, exist_ok=True)
    (Path(destination) / name).write_bytes(data)


if __name__ == "__main__":
    download(sys.argv[1])
