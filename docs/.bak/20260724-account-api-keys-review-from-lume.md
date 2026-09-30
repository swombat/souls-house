# Review: Account-managed AI API keys — from Lume

Reviewed 2026-07-24, uncommitted working tree on `master` (38 changed files, 2 new: migration + refresh job). Focus: insecure code and un-Rails-like practices, per Daniel's request.

## Verdict

The overall shape is good — genuinely Rails-idiomatic in most places. One **high-severity leak** needs fixing before this is committed, and one authorization question needs a deliberate answer. The rest is nits.

---

## 1. HIGH — plaintext API keys land in `audit_logs.data`

`AccountsController#update_account_settings` calls `audit_account_changes` → `audit_with_changes(:update_account_settings, @account)` (application_controller.rb:73), which does:

```ruby
changes = record.saved_changes.except(:updated_at)
```

`saved_changes` on an `encrypts` attribute returns **decrypted plaintext** — Active Record Encryption operates at the type layer, so change-tracking sees cast (decrypted) values. So the moment anyone saves an API key, `{"anthropic_api_key" => [nil, "sk-ant-…"]}` is written verbatim into the plain-jsonb `audit_logs.data` column and rendered in `admin/audit-logs.svelte`.

This defeats the entire point of `encrypts` on those columns: the keys sit unencrypted at rest, in every DB backup, and on an admin screen.

Note the path is *new*: keys didn't flow through `audit_with_changes` before this change (`github_pat` is set in `Agents::PromoteController` without it), so this isn't a widened pre-existing hole — it's introduced here.

**Suggested fix** (covers future cases too, not just this one):

```ruby
def audit_with_changes(action, record, **extra_data)
  return unless Current.user

  changes = record.saved_changes.except("updated_at")
  changes = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(changes)
  audit(action, record, **extra_data.merge(changes.symbolize_keys))
end
```

The existing `filter_parameters` config already includes `:_key`, so every `*_api_key` gets masked to `[FILTERED]` while the audit still records *that* the key changed — which is the signal you actually want. (Check what it does to the `[old, new]` array shape; `ParameterFilter` handles nested structures, but eyeball the output once.)

## 2. MEDIUM — any confirmed member can set/replace account keys

`set_account` uses `find_current_user_account!`, which resolves for **any confirmed member**, any role. So a plain member can:

- replace the account's `openrouter_api_key` with one pointing at a proxy they control — whoever controls the key controls where the account's LLM traffic (i.e. everyone's conversations) is sent;
- clear or burn keys the owner configured.

Account-name editing was already member-level, so this follows the existing pattern — but keys raise the stakes qualitatively. This may be a deliberate call (HelixKit accounts are small and high-trust), but it should be a *decision*, not an inheritance. If not deliberate: gate the AI-key attributes (or the whole settings update) on owner/admin membership role.

## 3. LOW — keys as docker CLI args (pre-existing)

`Agents::Sandbox#provider_env_args` passes keys as `-e NAME=value` on the `docker` command line — visible in `ps` output to any user on the host. This pattern predates this change, but it now carries per-account customer keys rather than only the operator's own. Consider `--env-file` with a 0600 tempfile, when convenient. Not a blocker for this changeset.

## 4. LOW — `public_send` before provider validation

`Account#ai_api_key` calls `public_send("#{provider}_api_key")` before `AI_PROVIDERS.fetch(provider)` validates the symbol. The `_api_key` suffix constrains it so it's not exploitable, but flipping the order (fetch first, then read) is free defense-in-depth and turns unknown providers into a clean `KeyError`.

---

## What's done well (worth saying explicitly)

- **`encrypts` on all six key columns**, non-deterministic. Correct tool, correctly applied.
- **Serialization is tight** — `json_attributes ... except: [:github_pat, *keys]`, and the concern's `merge_json_options` *unions* `except:` so runtime callers can't accidentally drop it. Notably: before this change there was **no** `except:` at all, and the concern's `serializable_hash` includes every column by default — meaning `github_pat` was previously being decrypted into every account JSON payload sent to the frontend. Mira's `except:` fixes that pre-existing leak. Good catch (worth its own commit message line so it isn't lost).
- **Frontend never round-trips key material.** The edit page receives only `ai_api_keys_configured` booleans; inputs are `type="password"` / `autocomplete="off"`; blank-keeps / explicit-clear-list is the standard masked-credential pattern, and the server-side `account_params` handling of it is clean.
- **Mass assignment is properly scoped**; `use_system_ai_credentials` is *not* in the member-facing permit list — only the site-admin route can flip it, and that route is audited (booleans only — no key material).
- **Request-log filtering already covers the new params** — `:_key` in `filter_parameters` matches `*_api_key`.
- **The refresh job** is sensible: per-agent requeue when a turn is active, `retry_on SandboxError`, scoped to externally-hosted agents with containers. One unbounded edge: an agent whose turn never ends requeues every 5 minutes forever. A max-defer count would cap it; minor.
- **Migration** is reversible and the `use_system_ai_credentials = TRUE` backfill preserves behavior for existing accounts while defaulting new ones to bring-your-own-keys. Right call.

## Rails-practice nits

- The `default_conversation_mode` removal (validation, store_accessor, frontend radio group) is bundled into the same changeset as the API-keys feature. No leftover references — the removal itself is clean — but it belongs in its own commit.
- `Account#ruby_llm_context` builds a fresh `RubyLLM.context` per call (`Chat#to_llm`, every `Prompt` execution). Correct, slight object churn; fine unless profiling says otherwise.
- When an account has `use_system_ai_credentials: false` and no keys, `resolve_provider` falls through to `:openrouter` with a nil key and the request fails with a provider error rather than a "no API key configured for this account" message. A guard with a clear error would save a support round-trip.

## Not verified

The test suite doesn't boot on this machine — VCR 6.3.1 is incompatible with Ruby 4.0 (`CGI.parse` was removed), which is an environment issue independent of this diff. Test *reading* shows coverage for the new params handling, encryptor delegation, and the refresh job, but I could not run them locally.
