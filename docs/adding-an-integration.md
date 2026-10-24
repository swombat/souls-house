# Adding an integration

How to add a service people connect under Settings → Integrations, and in particular a second provider for something the house already does (a second tweet-search provider next to TwitterAPI.io, say). Read [CONTRIBUTING.md](../CONTRIBUTING.md) first. This page covers what an integration has to include and what it must not touch.

## Before writing code

Open an issue (or comment on the existing one) with the scope, how you mean to do it, the tests you'll add and what you won't do, as [ADR 0002](decisions/0002-reviewed-development.md) asks for major work. Wait for a maintainer to say yes before building. A second provider for an existing feature is major work: it touches how people's money is spent.

A new provider **sits alongside** what exists. It does not replace it, change its behaviour or reshape its tables for everyone. An account that never connects the new provider must see no difference at all. Every existing test has to pass unchanged. If you find you need to edit an existing test, that's a sign you've changed existing behaviour: say so in the PR and explain why.

## The parts of an integration

Every integration has the same three parts. Copy the closest existing one. For a key-only service, `twitterapi_io` and `pipedrive` are the smallest.

1. **A catalog entry** in `app/models/services/catalog.rb` (`Services::Definition.register`). It gives the stable `key` (`snake_case`, never renamed later), `name`, `management_scopes` (`account_managed` for anything that spends the account's money), `connection_method` (`credentials` for a pasted key), `credential_strategy` (`static` for a key that doesn't refresh), `api_origins`, `documentation` links, `credential_fields` (the form, with `type: "password"` for secrets and `help` text saying where to find the key), `runtime_notes` (what a resident granted the key needs to know: how to send it, what each call costs, what not to do) and `adapter_class`. Use `requires_env` if the service can't work without host configuration.
2. **An adapter** in `app/models/services/<name>_adapter.rb`. `connection_attributes(credentials:, user:)` checks the credential against the provider **with a call that costs nothing** (a balance or account-info endpoint) and returns the connection attributes. `revoke(connection)` says what disconnecting does. Follow `Services::TwitterApiIoAdapter`:
   - Raise `Services::AdapterError` subclasses with short messages. Never put the response body in an error or a log: it can echo the request, and the request carries the key.
   - Store the key only in `credential_payload`. Fingerprint it with the HMAC in `credential_fingerprint`; never store or log it any other way.
   - Write an `authority_summary` in plain words: what the key lets the house do and what it can't do.
   - Set timeouts, and `max_retries = 0` on anything billed (Net::HTTP silently retries GETs).
3. **Tests**: `test/models/services/<name>_adapter_test.rb` with stubbed HTTP for a good key, a refused key, an unreachable provider and an unreadable answer. No test may call the real provider or need a real key.

Then the [CONTRIBUTING.md](../CONTRIBUTING.md) parts: a `config/changelog.yml` entry and a line in `app/frontend/lib/components/features/feature-list.js`.

## A second tweet-stream provider

Tweet streams (Field → tweets) are wired to TwitterAPI.io in more places than the catalog. Here is what each place does today, and what a second provider must do alongside it without changing it.

| Today | Where | What a second provider needs |
|---|---|---|
| Which connection pays: the account's `twitterapi_io` connection, else the house key if a site admin granted it, else nobody | `FieldTweets.integration_for`, `funding_for`, `key_for` | A rule for an account with both providers connected, proposed in the issue before you build it. An account that has an integration of its own never falls back to the house key; keep that. The house key stays TwitterAPI.io. |
| The search client: `TwitterApiIo#search(query, cursor:)` returns a `Page` (`tweets`, `next_cursor`, `has_next_page`) | `app/lib/twitter_api_io.rb`, `FieldTweets::Sync#client_for` | A client with the same interface. Each tweet must reach `FieldTweet.attributes_from` in the shape it reads (`id`, `author.userName`, `createdAt`, `text`, `isReply`/`inReplyToId`, `quoted_tweet`, `retweeted_tweet`, …): map the provider's fields in the client, not in `FieldTweet`. |
| The query: `from:handle since_time:… until_time:…` plus reply, quote and repost filters, so the house never pays for tweets it then throws away | `TwitterApiIo.window_query`, `FieldTweetSource#query_for` | The same bounded window and the same filters, done by the provider's query, not by filtering afterwards. |
| Errors: `TwitterApiIo::Error` with `funding?` (401/402/403: a person must act), `transient?` (retry later) and `answered_ok?` (a 2xx we couldn't read: the cost is unknown, not zero) | `app/lib/twitter_api_io.rb`, `FieldTweets::Sync` | The same three answers for the new provider's statuses, so the sync rescues and schedules it the same way. Messages to people name the provider they connected. |
| Spend: each page is **reserved before it is asked for**, at the most a page can cost (`TwitterApiIo.page_reserve`), under one lock, then settled at what it actually cost (`charge_for(returned)`). An error status is charged the per-call minimum; no answer at all keeps the whole reservation (`uncertain`) | `FieldTweets.reserve!`, `FieldTweetCall#settle!`, `#fail!` | The provider's own prices. A per-call price is a reservation equal to the call price, settled at the call price. Each `FieldTweetCall` has to record which provider it was made with, so it settles at that provider's prices. The account's own monthly limit and the daily import cap apply exactly as they do now. |
| A change to who pays restarts a stopped stream | `ServiceConnection#tweet_funding_changed?` | The same for the new provider's connections. |
| "Set up a TwitterAPI.io integration" links and messages | `FieldTweets::NO_FUNDING`, `app/lib/field_items.rb`, `FieldTweets::Sync` | Wording that offers either provider, without changing what TwitterAPI.io users see beyond that. |

Tests for this part: a stream paid by the new provider reserves, settles, fails and goes `uncertain` at the new prices; an account with only TwitterAPI.io reserves and settles exactly as before; the rule for an account with both picks the right key; a refused key puts the stream in needs-attention with the right provider named; and nothing falls back to the house key.

## Review

Open the PR from a branch, link the issue, list the checks you ran (`AGENTS.md`, "Commit & Pull Request Guidelines") and say which parts of the table above you changed. A maintainer reviews the head commit before merge. Anything that changes how existing spend is reserved or settled gets a second reviewer.
