# Credentials Audit — What a Fork Needs to Boot (2026-09-07)

Read-only audit for Phase 3 of the forkable-house plan. No secret values are reproduced below.

## The blocking finding

`config/credentials/{development,test,production}.yml.enc` are all **committed to git**; the matching `.key` files are gitignored (confirmed: not in `git ls-files`, present locally only because this checkout already has them). A fresh fork gets the encrypted blobs with no way to decrypt them.

`config/honeybadger.yml` calls `Rails.application.credentials.dig(:honeybadger, :api_key)` via ERB, and the honeybadger gem loads this file unconditionally on every boot in every environment (the `development_environments` key only suppresses *reporting*, not *loading*). Since the `.yml.enc` file exists but no key exists, `ActiveSupport::EncryptedFile` raises `MissingKeyError` the moment the file is decrypted — **this crashes boot in development, test, and production alike**, before any app code runs. This is a stricter requirement than any individual integration: a fork cannot even run `bin/rails db:create` until it's resolved.

Two ways to resolve it, per environment:
1. Obtain the real `.key` file from a colleague (as `docs/dev-credentials.md`/README already describe for development), or
2. Delete the committed `.yml.enc` for that environment and run `bin/rails credentials:edit --environment <env>`, which generates a fresh key + encrypted file with no dependency on the original secret.

No custom credentials path/environment logic exists in `config/application.rb` — Rails 8 defaults apply, so option 2 is a standard `credentials:edit` with no extra prerequisites.

## Credential keys in use

| Key path | Used in | Required? | Behaviour when absent | Notes |
|---|---|---|---|---|
| `smtp.*` (server, port, domain, user_name, password) | `config/environments/production.rb:64-73` | **Boot-conditional** | Guarded by `if credentials.dig(:smtp).present?` — falls back to default (no-op) mailer if absent. Safe. | Not required to boot. |
| `aws.access_key_id`, `aws.secret_access_key`, `aws.s3_region`, `aws.s3_bucket` | `config/storage.yml` (Active Storage `:amazon` service, selected in production.rb:25) | **Required in production** | Any file upload attempt raises at request time (S3 client init fails); boot itself is fine (ERB just interpolates nil into YAML). | Only bites when someone uploads a file. Fork should either populate these or switch `config.active_storage.service` to `:local`. |
| `aws.postgres_bucket` | `app/jobs/database_backup_job.rb:80-90`, `lib/tasks/db_backup.rake` | Optional (backup job only) | `bucket_name` raises `ArgumentError` if missing; `creds[:access_key_id]` on a nil `aws` credentials hash raises `NoMethodError` first if `aws:` block is missing entirely. | Only triggered by the scheduled/manual backup job, not boot. |
| `honeybadger.api_key` | `config/honeybadger.yml` | **Effectively required to exist as a decryptable value (see above), but nil value itself is fine** | If the credentials *file* decrypts successfully but the key is simply absent, Honeybadger just runs unconfigured/no-op. The crash only happens if the file can't be decrypted at all. | See blocking finding. |
| `app.url` | `agent_credentials_encryptor.rb`, `telegram_notifiable.rb:122`, `telegram_notification_job.rb:14`, `x_integration_controller.rb:75`, `github_integration_controller.rb:110`, `api/v1/telegram_messages_controller.rb:255`, `config/initializers/house.rb` | Optional | Most call sites fall back to `request.base_url` or `ENV["SOULSHOUSE_APP_URL"]`/`SOULSHOUSE_PUBLIC_URL`. **Two do not**: `telegram_notifiable.rb:122` and `telegram_notification_job.rb:14` interpolate directly with no fallback, producing a broken URL (leading with nothing) rather than crashing — degrades silently rather than erroring. | Not boot-blocking; only affects Telegram integration links if unset. `house.rb` initializer already recommends `SOULSHOUSE_PUBLIC_URL` for forks. |
| `agent_credentials_signing_key` | `agent_credentials_encryptor.rb:91` | Optional | Falls back to `Rails.application.secret_key_base`. Safe. | |
| `ai.openrouter.api_token`, `ai.claude.api_token`, `ai.open_ai.api_token`, `ai.gemini.api_token`, `ai.xai.api_token`, `ai.zai.api_token`, `ai.moonshot.api_token`, `ai.minimax.api_token` | `Account::AI_PROVIDERS` (`app/models/account.rb:14-38`), consumed via `system_ai_api_key` | Optional | Falls back to matching `ENV["...API_KEY"]`; if both absent, `nil` — the app runs, but that provider is unusable as a *system* credential (accounts can still supply their own key via `ai_api_key`). Values starting with `<` (placeholder) are treated as absent. | Fully degrades gracefully. |
| `ai.eleven_labs.api_token` | `lib/eleven_labs_stt.rb:38`, `lib/eleven_labs_tts.rb:45` | Optional | Raises a domain `Error` only when the STT/TTS feature is actually invoked. | Not boot-blocking. |
| `ai.gemini.api_token` (also read directly) | `app/services/youtube_video_reader.rb:26` | Optional | Falls back to `ENV["GEMINI_API_KEY"]`; `ensure_configured!` presumably raises only on use. | |
| `ai.xai.api_token` (also read directly) | `app/services/x_reader.rb:39` | Optional | Falls back to `ENV["XAI_API_KEY"]`. | |
| `oura.client_id`, `oura.client_secret` | `app/models/services/oura_adapter.rb`, `app/models/concerns/oura_api.rb` | Optional (integration) | Raises `ArgumentError` only when a user actually starts the Oura OAuth flow. No fallback env var. | Integration is opt-in per the README; degrades cleanly at request time. |
| `dropbox.app_key` / `dropbox.client_id` | `app/models/services/dropbox_adapter.rb:100-103` | Optional | Falls back to `ENV["DROPBOX_CLIENT_ID"]`; raises `ArgumentError` only on OAuth attempt. | |
| `google_workspace.client_id`, `google_workspace.client_secret` | `app/models/services/google_workspace_adapter.rb:227-236` | Optional | Falls back to `ENV["GOOGLE_WORKSPACE_CLIENT_ID/SECRET"]`; raises only on OAuth attempt. | |
| `github.*` (token/client keys, exact sub-keys not enumerated by this grep) | `app/models/concerns/github_api.rb:97` | Optional | Raises `ArgumentError` only when the specific GitHub API action is invoked. | GitHub *repository* credentials (`github_token_adapter.rb`) are per-connection user input, not app-wide credentials — unrelated to this key. |
| `x.*` (X/Twitter OAuth keys) | `app/models/concerns/x_api.rb:92` | Optional | Raises `ArgumentError` only when the X integration is used. | |
| `azure_storage.storage_access_key` | `config/storage.yml` (commented out) | N/A | Not active; commented example only. | |

## Test environment

Test gets credentials the same way as any Rails env: `config/credentials/test.yml.enc` + `config/credentials/test.key` (gitignored, present in this checkout, not committed). No stubbing found in `test/test_helper.rb`; nothing overrides `Rails.application.credentials` for tests. `config/environments/test.rb` doesn't reference credentials at all (mailer forced to `:test` delivery, no SMTP needed). So test boot has the exact same `honeybadger.yml`-triggered key dependency as development/production — a fork needs a `test.key` too, not just `production.key`.

## Documentation status

- `docs/dev-credentials.md` only documents a local dev login (email/password), not credential keys — misleadingly named for what it contains; doesn't mention the honeybadger/`.yml.enc` boot dependency at all.
- `README.md` installation section (lines 78-104) documents `aws`, `ai.claude/open_ai/openrouter`, `smtp`, and `honeybadger` credential blocks for development, and says "obtain the credential keys from a colleague, or `rails credentials:edit --environment development`." This is accurate for what it lists, but it's silent on: `ai.gemini`/`ai.xai`/`ai.eleven_labs`/`ai.zai`/`ai.moonshot`/`ai.minimax`, `oura.*`, `dropbox.*`, `google_workspace.*`, `github.*`, `x.*`, `app.url`, `agent_credentials_signing_key`, `aws.postgres_bucket`. It also doesn't mention that skipping the `honeybadger:` block entirely (rather than leaving it with an empty value) is what actually causes the crash — a developer following the doc verbatim (adding the block with a real key) never hits the bug, which is presumably why it's gone unnoticed.

## Proposed minimal production credentials template

```yaml
# REQUIRED for the app to boot at all (see "blocking finding" above):
# this file itself must exist and be decryptable — i.e. production.key must
# be present, or config/credentials/production.yml.enc must be freshly
# generated via `bin/rails credentials:edit --environment production`.

# REQUIRED if config.active_storage.service stays :amazon (config/environments/production.rb).
# Switch that to :local instead if you don't want to set these up.
aws:
  access_key_id: ...
  secret_access_key: ...
  s3_region: ...
  s3_bucket: ...
  # OPTIONAL — only needed for the scheduled database backup job:
  # postgres_bucket: ...

# OPTIONAL — omit this whole block to disable outgoing mail (guarded, degrades cleanly).
# smtp:
#   server: ...
#   port: 587
#   domain: souls.house
#   user_name: ...
#   password: ...

# OPTIONAL — omit to run Honeybadger unconfigured (no-op). Do NOT omit the
# surrounding credentials FILE itself; only this key/value is optional.
# honeybadger:
#   api_key: ...

# OPTIONAL — system-wide AI provider keys; individual accounts can supply
# their own instead. Omit any you don't want to provide platform-wide.
# ai:
#   claude:
#     api_token: ...
#   openrouter:
#     api_token: ...
#   open_ai:
#     api_token: ...
#   gemini:
#     api_token: ...
#   xai:
#     api_token: ...
#   eleven_labs:
#     api_token: ...

# OPTIONAL — each of these enables one integration; all degrade to a
# request-time error only when a resident actually tries to connect that
# service, never at boot.
# oura:
#   client_id: ...
#   client_secret: ...
# dropbox:
#   app_key: ...
# google_workspace:
#   client_id: ...
#   client_secret: ...
# github:
#   (sub-keys not fully enumerated by this audit — see app/models/concerns/github_api.rb)
# x:
#   (sub-keys not fully enumerated by this audit — see app/models/concerns/x_api.rb)

# OPTIONAL — public URL for webhook/link generation outside a request.
# Prefer the SOULSHOUSE_PUBLIC_URL env var instead (config/initializers/house.rb
# already prefers it); only set this if not using that env var.
# app:
#   url: https://your-fork.example.com

# OPTIONAL — falls back to Rails.application.secret_key_base if omitted.
# agent_credentials_signing_key: ...
```

## Code sites that would benefit from a guard

1. `app/models/concerns/telegram_notifiable.rb:122` and `app/jobs/telegram_notification_job.rb:14` — interpolate `credentials.dig(:app, :url)` with no fallback (unlike the four other `app.url` call sites, which all fall back to `request.base_url` or an ENV var). Produces a malformed URL rather than an error; worth aligning with the other call sites' fallback pattern.
2. `app/jobs/database_backup_job.rb:80-84` (`aws_credentials`) — `Rails.application.credentials.aws` returns `nil` if the `aws:` block is entirely absent, and `creds[:access_key_id]` on `nil` raises `NoMethodError` rather than the intended `ArgumentError` message from `bucket_name`. A `.presence || {}` guard would produce a clearer error for forks that skip AWS entirely.
3. `config/storage.yml` / `config/environments/production.rb:25` — a fork that doesn't want S3 has no documented path to switch `config.active_storage.service` to `:local`; worth a comment pointing at this, since the `aws:` keys are otherwise a hard production requirement.

---

## Correction (Lume, verified 2026-09-07 17:05)

The headline above is wrong in development and test. No environment sets
`config.require_master_key`, so `raise_if_missing_key` is false everywhere;
with the `.yml.enc` present and no key, `ActiveSupport::EncryptedConfiguration`
rescues `MissingContentError` and returns an empty config — `credentials.dig`
yields `nil`, `config/honeybadger.yml` renders `api_key: ""`, and the app boots.
Verified directly against `config/credentials/development.yml.enc` with a
non-existent key path: `dig(:honeybadger, :api_key) → nil`; only
`raise_if_missing_key: true` raises `MissingKeyError`.

What *does* bite a fork: a **wrong** key. If a fork generates a fresh
`production.key` while the upstream `production.yml.enc` is still in place,
decryption raises `ActiveSupport::MessageEncryptor::InvalidMessage` at first
credentials access. So the fork procedure is *delete the upstream `.yml.enc`
for each environment, then `bin/rails credentials:edit --environment <env>`*
— which is what `bin/house init` should do (Phase 3).
