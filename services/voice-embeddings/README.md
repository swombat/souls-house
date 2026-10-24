# voice-embeddings

Private CPU WeSpeaker embeddings for Field voiceprints. This is the Python
service slice of ADR 0006 / approved scope #504, **not a deployment or permission
to reuse ECAPA vectors or thresholds**.

## Engine and reproducibility

- Public checkpoint: `pyannote/wespeaker-voxceleb-resnet34-LM` at
  `837717ddb9ff5507820346191109dc79c958d614` (model card: CC-BY-4.0).
- Exact profile:
  `wespeaker-voxceleb-837717ddb9ff-pyannote-4.0.7-torch-2.14.1-whole-v1`.
  Startup rejects differing pyannote.audio or torch versions rather than
  advertising that profile for another implementation.
- pyannote.audio `Model.from_pretrained` receives only the verified local
  `pytorch_model.bin`; its embedded architecture/config is sufficient.
  `Inference(window="whole", device=cpu)` receives the entire mono float32
  waveform, divided by 32768 from PCM16. Exactly one inference call, then
  float64 L2 normalization to a finite, nonzero unit **256-vector**. No
  averaging, cropping, chunking, sliding windows, VAD or resampling.
- Every Python dependency is pinned in `requirements.txt`, resolved and
  installed against public PyPI and the PyTorch CPU index on Linux x86_64 /
  CPython 3.11.17 on 2026-10-23; `uv pip check` passes (95 packages).
  The Docker base remains Python 3.11.13. Torch `2.14.1+cpu` works with the
  available torchaudio `2.11.0+cpu` and torchcodec `0.17.0+cpu`. There is no
  torchaudio `2.14.1+cpu` release at resolution time. **No profile pin change
  was needed.** Other architectures and the actual image build remain untested.
- No Docker was available in the implementation environment. A clean image
  build / smoke test remains a release gate; dependency resolution and real
  local-checkpoint inference were tested in an isolated public-only venv.

### Checkpoint integrity evidence

The pinned public Hugging Face tree API reports `pytorch_model.bin` as
26,645,418 bytes, LFS SHA256:

```text
366edf44f4c80889a3eb7a9d7bdf02c4aede3127f7dd15e274dcdb826b143c56
```

Sources (no credentials or private audio):

- `https://huggingface.co/api/models/pyannote/wespeaker-voxceleb-resnet34-LM/tree/837717ddb9ff5507820346191109dc79c958d614`
- `https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM/resolve/837717ddb9ff5507820346191109dc79c958d614/pytorch_model.bin`

The actual downloaded file independently hashes to that value. `download.py`
fetches only that public URL with standard-library HTTPS (no implicit Hub token
discovery), verifies the committed manifest, and only then writes the file.
Startup rechecks SHA256 before deserializing the checkpoint; missing or changed
weights fail closed. No runtime download/config lookup is needed.

## API and privacy

Bearer token `VOICE_EMBEDDING_TOKEN` (24+ characters) on `/embed`; `/health`
remains unauthenticated.

- `GET /health` → `{"ready": true, "profile": "...", "dimensions": 256}`.
  Only served after verified model loading and successful synthetic warmup.
- `POST /embed`: WAV mono, 16 kHz, 16-bit PCM; 0.5–120 s, body at most
  8 MiB. Returns `{"embedding": [256 floats], "profile": "..."}`.
- Bad WAV / inference failure: `400 {"error": "Invalid audio"}`.
  Bad body length / transfer encoding: `400 {"error": "Invalid request"}`.
  Missing/wrong bearer: `401 {"error": "Unauthorized"}`.
  Unknown routes: `404 {"error": "Not found"}`. A busy gate returns 503.
- One inference at a time, two torch intra-op threads, one inter-op thread.
  Bounded body reads happen inside the same gate. No request files, audio,
  vectors, paths, credentials or response bodies are logged. JSON responses use
  `Cache-Control: no-store`.
- `PYANNOTE_METRICS_ENABLED=0`, `HF_HUB_DISABLE_TELEMETRY=1`,
  `HF_HUB_OFFLINE=1` and `DO_NOT_TRACK=1` are forced **before model-library
  imports**. Runtime should still have no egress. No resident credentials or
  private audio/manifests were used in implementation or tests.
- Container remains uid 10001, no public port. Deployment must retain the
  existing read-only filesystem, tmpfs `/tmp` and disabled core dumps.

## Resource evidence — enforced 2 GiB smoke passed

**Do not deploy this recipe into a 1 GiB accessory.** On
2026-10-23, the real pinned checkpoint / dependencies, synthetic Gaussian
float32 input (seed 0), affinity restricted to two CPUs, two torch/BLAS threads:

| Whole clip | Elapsed | Process CPU | Peak process RSS |
| --- | ---: | ---: | ---: |
| 2 s warmup | 0.053 s | 0.107 s | 611,128 KiB |
| 120 s | 4.859 s | 9.648 s | **1,246,624 KiB (1.19 GiB)** |

Both outputs had 256 components and unit norm. `ru_maxrss` includes import,
load and warmup; these are single-run process measurements, not a cgroup peak
or latency guarantee. The host's cgroup limit was 8 GiB, **not 1 GiB**; the
120-second pass succeeds there but its RSS alone exceeds the production budget.
This is measured evidence that the 1 GiB budget is insufficient, not an enforced
1 GiB OOM test. No windowing or recipe change has been made to hide it.

Lume approved the proposed accessory increase to **2 GiB**, keeping **2 CPUs**
unchanged. That approval is not proof of fitting the revised limit: an operator
must run the actual image from the PR head under `--memory=2g`, covering
**30 s, 60 s and 120 s** after a 2 s warmup, before final approval. This enforced
container smoke passed for `f4765e45` on the production host, with no deployment:
[Lume's receipt](https://github.com/swombat/souls-house/pull/505#issuecomment-6353133462).
The image exited zero, `OOMKilled=false`, and cgroup `memory.max=2147483648`.
Process RSS peaks were **834 MiB / 915 MiB / 1,183 MiB** for 30/60/120 s;
all outputs had unit norm and 256 dimensions. The 120 s run took 5.38 s.
The cgroup's exact `memory.peak` was unavailable after exit; sampled
`memory.current` is not substituted for that peak. The earlier table above
records the separate venv measurement, not this enforced-container result.

Reproduce with the production dependencies and a public checkpoint directory:

```sh
python services/voice-embeddings/download.py /tmp/public-wespeaker
OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 OPENBLAS_NUM_THREADS=2 \
  taskset -c <two-available-cpus> python services/voice-embeddings/benchmark.py \
  --model-dir /tmp/public-wespeaker
```

The benchmark generates samples in memory, emits only timing/resource/shape/norm
aggregates, and never reads audio or a token.

Operator smoke command (replace `IMAGE` with the image built from the reviewed
PR head; retain its digest and stdout/exit status in the PR):

```sh
docker run --rm --network none --read-only --tmpfs /tmp \
  --memory=2g --memory-swap=2g --cpus=2 --ulimit core=0 \
  IMAGE python benchmark.py --model-dir /model
```

The image includes `benchmark.py`; it loads and verifies the same pinned local
checkpoint and executes whole-clip 2/30/60/120 s inference. Success must include
all four result lines, finite unit 256-vectors and exit status zero. The JSON
reports process RSS, not total cgroup peak; capture container/cgroup peak and OOM
status separately when available. A 2 GiB pass must not be inferred merely from
the earlier unconstrained 1.19 GiB process measurement.

## Tests

```sh
python -m unittest discover -s test -p 'voice_embeddings*_test.py' -v
```

Contract tests require numpy but mock torch/pyannote and use a real loopback HTTP
server. They cover whole-clip input, exact profile/version rejection, output
shape/norm/nonfinite rejection, verified local loading, readiness failure,
download integrity, auth/routes, WAV/body bounds, generic errors, no request
logging, and serialized inference. Existing WAV tests remain unchanged.

19 mocked/WAV/benchmark tests passed on 2026-10-23. An additional opt-in subprocess smoke
test uses the real pinned dependencies and public checkpoint, an empty home,
no inherited credentials, and rejects every socket connection attempt **before
imports**. It passed for 0.5 s and 2 s synthetic input, with pyannote metrics
confirmed disabled and zero network attempts:

```sh
VOICE_EMBEDDINGS_PUBLIC_TEST_MODEL_DIR=/tmp/public-wespeaker \
  python -m unittest discover -s test -p 'voice_embeddings*_test.py' -v
```

## Deployment / rollback boundaries

The Rails integration and operational sequence are documented in
[`docs/operations/voice-engine-rollout.md`](../../docs/operations/voice-engine-rollout.md).
ADR 0006 requires profile-separated caches, retained-audio re-embedding and
print rebuilding, stale-probe/guess/validation invalidation and
WeSpeaker-specific validation.
Never compare a 192-D ECAPA vector with this engine's 256-D output.

After those gates and the memory/image gate above, the existing image release /
accessory boot process still applies (`HOUSE_VOICE_EMBEDDINGS_IMAGE`,
`bin/house release-voice-embeddings`, private `VOICE_EMBEDDING_TOKEN`, then
`bin/kamal accessory reboot voice-embeddings`). Daniel authorized this reviewed
implementation and deployment; the test/review gates still apply. Preserve the
old ECAPA image/profile for rollback, using the new Rails profile-switch task
rather than reverting code over converted data.
