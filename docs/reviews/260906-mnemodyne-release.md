# Mnemodyne production release — September 6, 2026

Daniel authorized integration, push and deployment at 08:31 CEST.

## Integrated and published

- Integrated upstream `cabe01a` (admin runtime-session output) by rebasing the
  six reviewed commits. Pushed `681e1bc` to `origin/master` normally, without
  force. User-authored local review and routes whitespace remain untouched.
- Rechecked the integrated release: **2,189 Rails tests / 11,034 assertions,
  zero failures/errors/skips; 18 browser tests passed; real local image smoke
  1 test / 49 assertions passed**. Logs: `log/mnemodyne-release-{rails,browser,smoke}.log`.
- Built the embedding image natively on the production amd64 Docker host and
  published `dtenner/souls-house-mnemodyne-embeddings:681e1bc`.
  Independently inspected the published registry manifest:
  **`sha256:a27b4e9f1d24645c9bd21126f66119837054bad41c19102f1fc836db5006f08a`**.
  Use this value for `MNEMODYNE_EMBEDDING_IMAGE_DIGEST`.
- Existing deployment credentials were copied read-only from the primary
  checkout into ignored, mode-0600 files in instance 2. A new 64-character
  embedding bearer token was generated at
  `config/credentials/deployment/mnemodyne_embedding_token.key`; its value is
  not in logs or source control. Do not regenerate it when resuming this release.

## Production preflight and current interruption

Production was running Rails `fffd2f433f8a4341872a26c377cc366d60176b94`.
All nine externally hosted residents were healthy and idle at preflight;
successful resident backups were recorded between 04:00:04 and 04:00:56 UTC
on September 6.

Preserved the old runtime as `helixkit-agent-runtime:pre-mnemodyne-20260906`,
image ID `sha256:be399fa9e2974c5606d4c33e8db413066a61c523fef69ea359d10a3d079ab078`.
The new runtime build uses the separate
`helixkit-agent-runtime-mnemodyne-candidate` repository, so it does not move
the residents' `latest` tag before verification.

That candidate build lost SSH during Rust compilation. Subsequent connections
to both `misc` and `95.217.118.47:12222` were refused. The cause is not established;
do not infer that the host rebooted, ran out of memory, or finished its build.
The attempted fresh pre-release full backup never started because SSH was
already unavailable. `https://souls.house/up` still returned HTTP 200 at
08:37 CEST.

**Not deployed:** the embedding accessory has not been booted, Rails/migrations
have not been released, and resident containers have not been replaced.
The last runtime build command failed; inspect actual remote image/process state
after SSH returns before retrying it.

## Resume once SSH access is restored

1. Recheck resident activity, host resources and candidate-build state. Take a
   fresh `FullBackupJob.perform_now(fail_fast: true)` backup while idle.
2. Finish and verify the amd64 runtime candidate using the pinned Chaos source
   in `agent-runtime/chaos-ref`; retain the recorded rollback image.
3. Export the published digest above for every Kamal invocation. Boot and
   internally health-check the private embedding accessory.
4. Deploy the current pushed master with `SOULSHOUSE_SKIP_AGENT_RECONCILE=1`
   so the post-deploy hook does not replace the fleet ahead of a canary.
   The normal pre-deploy hook builds/tags the reviewed runtime.
5. Verify migrations, web/jobs health and `mnemodyne:check`. Exercise the live
   memory path with a synthetic canary, without writing invented memories into
   real residents' graphs.
6. Reconcile resident containers through the supported lifecycle, respecting
   active turns. Verify actual image identity, installed hooks/guide, empty
   vault provisioning and initial paired checkpoints; then record completion.

All work remains in instance 2. No other development instance was modified.
