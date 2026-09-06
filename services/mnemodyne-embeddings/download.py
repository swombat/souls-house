"""Download public, revision-pinned weights at build time; never handles resident data."""
import sys
from huggingface_hub import snapshot_download

REVISION = "52398278842ec682c6f32300af41344b1c0b0bb2"
FILES = ["config.json", "model_optimized.onnx", "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "vocab.txt"]
if __name__ == "__main__":
    snapshot_download(repo_id="qdrant/bge-small-en-v1.5-onnx-q", revision=REVISION,
                      local_dir=sys.argv[1], allow_patterns=FILES)
