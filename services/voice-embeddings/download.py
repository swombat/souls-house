"""Download public, revision-pinned weights at build time; never handles resident data."""
import sys
from huggingface_hub import snapshot_download

REVISION = "0f99f2d0ebe89ac095bcc5903c4dd8f72b367286"
FILES = ["hyperparams.yaml", "embedding_model.ckpt", "mean_var_norm_emb.ckpt", "classifier.ckpt", "label_encoder.txt"]
if __name__ == "__main__":
    snapshot_download(repo_id="speechbrain/spkrec-ecapa-voxceleb", revision=REVISION,
                      local_dir=sys.argv[1], allow_patterns=FILES)
