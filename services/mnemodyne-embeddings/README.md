# Private Mnemodyne embeddings

CPU-only ONNX inference, with no paid API, resident training, query logging or
runtime model downloads. Rails sends only the bounded query/handle, never source
files. This service is an inference accessory, **not** a separate graph service:
the graph and all authorization remain in Rails and its primary database.

The image downloads public `qdrant/bge-small-en-v1.5-onnx-q` weights at revision
`52398278842ec682c6f32300af41344b1c0b0bb2`. Startup verifies the six files against
`model-sha256.json`, loads locally, and warms inference before reporting healthy.
Dependencies are pinned in `requirements.txt`.

- Profile: `bge-small-en-v1.5-q-52398278842e-fastembed-0.7.4-v1`
- 384 dimensions; English model, 512-token truncation.
- `GET /health`: readiness/profile/dimensions, no private data.
- `POST /v1/embeddings`: bearer-authenticated, OpenAI-shaped single-text request.
- Required secret: `MNEMODYNE_EMBEDDING_TOKEN`, at least 24 characters.
- One inference at a time; busy requests get 503 rather than an unbounded queue.
- Non-root, offline model loading; deploy without a public port.

From an isolated checkout:

```sh
mise exec -- scripts/build-local-mnemodyne-embeddings
mise exec -- scripts/build-local-agent-runtime
mise exec -- scripts/verify-mnemodyne-local
```

The verifier starts and cleans up its own loopback-published embedding container,
synthetic Rails resident, runtime container and encrypted local restic repository.
It does not use real resident files, model credentials or cloud storage. Downloads
at **build time** require internet access; inference does not.

See `docs/mnemodyne-deployment.md` for operator preparation and rollback. Changing
weights, tokenization or preprocessing requires a new profile and re-embedding;
never reuse a profile name for different vectors.
