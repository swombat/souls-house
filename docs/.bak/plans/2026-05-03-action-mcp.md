# Plan: Add ActionMCP server to HelixKit (spine for harness pilot)

**Date:** 2026-05-03
**Branch:** `harness-pilot-spine` (new)
**Estimated scope:** 1–2 hours of work
**Author:** Lume (with Daniel)
**Implementer:** Codex (this plan is for you)

## Context

HelixKit is going to host four AI agents (Wing, Claude, Grok, Chris) running on chaos (seuros's Rust-based agent harness, Apache 2.0). Each agent runs in its own Docker container on the build server, talks to HelixKit via MCP (Model Context Protocol) to read/post messages.

This plan covers **only the HelixKit side of the spine**: expose an MCP server endpoint that chaos-hosted agents can call into.

Full architecture document: `~/dev/lume/shared/memory/thoughts/helixkit_harness_architecture_2026-05-03.md`. Feedback thread on HelixKit: `WYNWQe` ([Build] Harnesses).

## Goal

Add an MCP server endpoint to HelixKit that exposes a single tool — `post_message(chat_id:, content:)` — authenticated by API key. Once an agent (running locally as a chaos process for testing) can post a message into a HelixKit chat via this endpoint, the spine integration is verified end-to-end.

## Scope

### In scope (this plan)

- Add the `actionmcp` gem to the Gemfile
- Run `action_mcp:install` generator + migrations
- Implement `ApplicationGateway` with API-key authentication (reusing existing `ApiKey` model)
- Implement `PostMessageTool` — exposes `post_message` to MCP callers, creates a `Message` in a `Chat`, attributed to the calling user (or to a configured agent — see Gotchas §3)
- Mount the MCP endpoint in `config/routes.rb`
- Verify locally: a curl with a valid bearer token + JSON-RPC body successfully creates a message visible in the chat UI

### Out of scope (separate work, do NOT do here)

- Other tools (`read_chat`, `list_whiteboards`, `get_chat_participants`, etc.) — phase 7 of the architecture doc
- HelixKit calling OUT to chaos containers (the trigger mechanism) — Lume is handling this side as a Python shim + Docker
- Consent rail / watchdog / proposed-branch review — phase 8
- Multi-tool exposure or full MCP capability surface — explicitly minimal for v1
- Real deployment — this is a local-dev verification

## Reference docs

- ActionMCP repo: <https://github.com/seuros/action_mcp>
- ActionMCP gem name on RubyGems: **`actionmcp`** (not `action_mcp`)
- README: full overview including consent management
- GATEWAY.md: authentication patterns — read this carefully before implementing the gateway
- TOOLS.MD: tool DSL reference

ActionMCP is Rails-engine-style. It generates `app/mcp/`. Network-only (no STDIO support, which is what we want — STDIO is not production-shape).

## Steps in order

### 1. Add the gem and install

```ruby
# Gemfile (add to a logical group — alongside other web/API gems)
gem "actionmcp"
```

```bash
bundle install
bin/rails action_mcp:install:migrations
bin/rails generate action_mcp:install
bin/rails db:migrate
```

The install generator creates:
- `app/mcp/application_gateway.rb` (auth gateway base)
- `app/mcp/application_mcp_tool.rb` (tool base class)
- `app/mcp/application_mcp_prompt.rb` (we won't use)
- `app/mcp/application_mcp_resource.rb` (we won't use)
- `config/mcp.yml` (per-env config)
- Migrations for ActionMCP's session/event tables

### 2. Wire up authentication via ApiKey

Reuse the existing `ApiKey` model. Pattern:

```ruby
# app/mcp/identifiers/api_key_identifier.rb
class ApiKeyIdentifier < ActionMCP::GatewayIdentifier
  identifier :user
  authenticates :api_key

  def resolve
    token = extract_bearer_token
    raise Unauthorized, "Missing bearer token" if token.blank?

    api_key = ApiKey.authenticate(token)
    raise Unauthorized, "Invalid API key" unless api_key

    api_key.touch_usage!(request.remote_ip) if respond_to?(:request)
    api_key.user
  end
end
```

```ruby
# app/mcp/application_gateway.rb (replace the generated stub)
class ApplicationGateway < ActionMCP::Gateway
  identified_by ApiKeyIdentifier

  def configure_session(session)
    session.session_data = {
      "user_id" => user.id,
    }
  end
end
```

Rationale: HelixKit already issues `hx_` prefix API keys (see `app/models/api_key.rb`). chaos's MCP client already supports `--bearer-token` / `--bearer-token-env-var` flags. No new auth scheme needed.

**Note** — `extract_bearer_token` parses the `Authorization: Bearer <token>` header. Verify that helper exists in the gem version we install; if it doesn't, parse `request.headers["Authorization"]` manually with a `Bearer ` prefix strip.

### 3. Implement `PostMessageTool`

```ruby
# app/mcp/tools/post_message_tool.rb
class PostMessageTool < ApplicationMCPTool
  tool_name "post_message"
  description "Post a message into a HelixKit chat as the authenticated agent/user."

  property :chat_id, type: "string",
    description: "The chat identifier (URL slug, e.g. 'WYNWQe').",
    required: true
  property :content, type: "string",
    description: "Message body. Markdown supported.",
    required: true

  def perform
    user = current_user

    # Resolve chat by whatever URL helper convention HelixKit uses for chat IDs.
    # Check Chat.to_param / friendly_id / hashid usage. If chats use account-scoped
    # IDs, you'll need to find the chat across all accounts the user is a member of.
    chat = Chat.find_by(public_id: chat_id) || Chat.find_by(slug: chat_id) || Chat.find(chat_id)

    unless chat && user_can_post?(user, chat)
      report_error("Chat not found or access denied")
      return
    end

    message = chat.messages.create!(
      user: user,
      content: content,
      role: "agent"  # or whatever role makes sense — see Gotchas §3
    )

    render(text: "Posted message #{message.id} into chat #{chat_id}")
  end

  private

  def user_can_post?(user, chat)
    # Reuse whatever authorization HelixKit already uses. Likely the user must be
    # a member of the chat's account, or chat has explicit participants.
    chat.account.members.include?(user) || chat.respond_to?(:participants) && chat.participants.include?(user)
  end
end
```

**Resolve before implementing:**
- How does HelixKit identify chats in URLs? (`Chat.find` by what?). Check `app/controllers/chats_controller.rb` and any `to_param` override.
- What's the right `role` value for messages from this tool? Existing `Message` records have a `role` enum/column — match conventions.
- What's the authorization predicate for "can this user post in this chat"? Look at `ChatsController` or `MessagesController` `before_action`s.

### 4. Mount the MCP endpoint

```ruby
# config/routes.rb (somewhere logical, near API/webhook routes)
mount ActionMCP::Engine => "/mcp"
```

The endpoint then accepts JSON-RPC POSTs at `POST /mcp`. ActionMCP handles initialization, tool listing, tool invocation, session management.

### 5. Configure for development

In `config/mcp.yml` (generated), ensure development is on. Example:

```yaml
development:
  authentication: ["api_key"]
  # any other dev-friendly settings
```

(Refer to ActionMCP README for the canonical config keys — they may evolve.)

### 6. Verification — local end-to-end

After install + migrations + boot:

```bash
# Start helix_kit
bin/dev

# In another shell — get an API key for your dev user (via the UI or rails console)
# Then test the MCP endpoint:

# 1. Initialize a session
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer hx_<your-api-key>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-test","version":"0.1"}}}'

# 2. List tools
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer hx_<your-api-key>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# 3. Call post_message
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer hx_<your-api-key>" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"post_message","arguments":{"chat_id":"<some-chat-id>","content":"Hello from MCP test"}}}'
```

Success criteria:
- Step 1 returns a session token
- Step 2 lists `post_message` in the available tools
- Step 3 returns a success response AND the message is visible in the chat UI under the user that owns the API key

### 7. Tests

Add at minimum:
- Gateway test: rejects missing/invalid bearer tokens, accepts valid ones
- Tool test: `post_message` creates a `Message`, returns success on valid input, error on missing chat / unauthorized

Match existing HelixKit testing conventions (Minitest? RSpec? Look at `test/` or `spec/`).

## Gotchas

### 1. Gem name vs Ruby module

The gem on RubyGems is `actionmcp` (one word). The Ruby module is `ActionMCP`. Don't confuse them in the Gemfile.

### 2. `extract_bearer_token` helper

Per the GATEWAY.md examples, this helper exists on `ActionMCP::GatewayIdentifier`. Verify it's available in the version we install. If not, parse `request.headers["Authorization"]` manually:

```ruby
def extract_bearer_token
  header = request.headers["Authorization"].to_s
  header.start_with?("Bearer ") ? header.sub(/\ABearer /, "") : nil
end
```

### 3. Message attribution: as user or as agent?

The existing `Message` model probably distinguishes user-authored from agent-authored messages (look at `role`, `from_user_id`, `agent_id`, etc.). The PostMessageTool should attribute the message in a way that matches whatever HelixKit uses for AI agents currently. Two reasonable options:

- **Attribute to the calling user**: simplest, matches what a "user posting via API" would do. The message looks like the user posted it.
- **Attribute to a specific Agent record**: requires the API key to be associated with an Agent, or the call to specify an `agent_id`. More accurate for the harness-pilot use case.

For v1 of the spine, attributing to the user is fine. Phase 2 work will introduce a per-agent API key + Agent association.

### 4. Don't break existing routes / controllers

ActionMCP mounts at `/mcp`. Verify nothing in HelixKit currently uses that path. (A grep for `'/mcp'` or `:mcp` in routes/controllers should suffice.)

### 5. Migration check

Run `bin/rails db:migrate` in development; verify in staging-like environment too if there's one configured. ActionMCP's tables are prefixed `action_mcp_*` and shouldn't collide.

## Branch & PR notes

- Work on a new branch: `harness-pilot-spine`
- Commit in logical chunks (gem add + install / gateway / tool / route / tests)
- PR title: "Add ActionMCP server with post_message tool (harness pilot spine)"
- PR description should reference this plan file and the architecture doc

## When done

When the verification curls pass and a message appears in the chat UI, ping Lume — Lume will then test the integration from a Docker container running chaos pointed at the local HelixKit MCP endpoint. That closes the loop on the spine.

## Open questions for later (don't address in this PR)

- Per-agent API keys vs user-shared keys (likely per-agent, scoped to specific chats)
- Tool surface for phase 2 (`read_chat`, `read_whiteboard`, `list_chats`, etc.)
- How to attribute messages to a specific agent identity (Wing/Claude/Grok/Chris) when the same user owns multiple agent API keys
- Streaming / progress for long-running operations
