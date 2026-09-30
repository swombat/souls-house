# DHH-Style Review: AI-Friendly JSON API Specification

**Reviewed:** January 15, 2026
**Verdict:** Mixed - Good foundations, but over-engineered in places

---

## Overall Assessment

This specification demonstrates reasonable Rails instincts in some areas but betrays a concerning tendency toward premature abstraction and over-engineering. The core API design is sound - REST endpoints, Bearer token auth, standard JSON responses - but the OAuth-style key request flow is solving a problem you do not yet have. The `GenerateSummaryPrompt` class introduces an abstraction layer that adds complexity without proportional benefit. The estimated "~600 lines" has already ballooned to "~900 lines" in the summary table, which is a red flag: scope creep before a single line of code exists.

The good news: the models are appropriately fat, the controllers are reasonably thin, and the database design is pragmatic. With some simplification, this could be a clean Rails API.

---

## Critical Issues

### 1. The OAuth Flow is Premature Complexity

The entire `ApiKeyRequest` model, the polling endpoints, the browser-based approval flow - all of this is solving an imaginary problem. Who is your user? Claude Code. How many users will use this API? Probably you and maybe a handful of others.

The OAuth dance adds:
- A new database table (`api_key_requests`)
- A new model with state machine logic
- Multiple new routes and controller actions
- Frontend pages for approval
- Polling infrastructure
- Expiration and cleanup logic

For what? So a CLI can request a key without copying it manually?

**The Rails Way:** Build the simplest thing that works. Create API keys in the browser. Copy them to your CLI config. Done. When you have 10,000 users demanding a smoother CLI onboarding experience, then build the OAuth flow. You can add this later with zero breaking changes to the existing API.

```ruby
# This is all you need for now:
class ApiKeysController < ApplicationController
  def index
    @api_keys = Current.user.api_keys.by_creation
    render inertia: "api_keys/index", props: { api_keys: @api_keys.map(&:as_json) }
  end

  def create
    @api_key = ApiKey.generate_for(Current.user, name: params[:name])
    render inertia: "api_keys/show", props: {
      api_key: @api_key.as_json,
      raw_token: @api_key.raw_token
    }
  end

  def destroy
    Current.user.api_keys.find(params[:id]).destroy!
    redirect_to api_keys_path, notice: "API key revoked"
  end
end
```

Three actions. No state machines. No polling. No expiration cleanup jobs. Delete the `ApiKeyRequest` model entirely.

### 2. The `GenerateSummaryPrompt` Class is a Service Object in Disguise

```ruby
class GenerateSummaryPrompt < Prompt
  # ... 40+ lines of abstraction
end
```

This is the kind of abstraction that makes Java developers feel at home and Rails developers weep. You have a `Prompt` base class, a subclass with template rendering, a separate ERB template directory - all to generate a single string.

**The Rails Way:** Put this in the model where it belongs.

```ruby
class Chat < ApplicationRecord
  SUMMARY_COOLDOWN = 1.hour

  def generate_summary!
    return summary unless summary_stale?
    return nil if messages.count < 2

    new_summary = call_llm_for_summary
    update!(summary: new_summary, summary_generated_at: Time.current) if new_summary.present?
    summary
  end

  private

  def call_llm_for_summary
    # Use whatever LLM client you have directly
    # This is ~10 lines of code, not a class hierarchy
    messages_text = recent_messages_for_summary
    RubyLLM.generate(
      model: "fast-model",
      system: "Summarize this conversation in under 200 characters. Be factual and concise.",
      prompt: messages_text
    ).truncate(200)
  end

  def recent_messages_for_summary
    messages.where(role: %w[user assistant])
            .order(:created_at)
            .limit(20)
            .map { |m| "#{m.role.titleize}: #{m.content.truncate(300)}" }
            .join("\n")
  end
end
```

No base class. No ERB templates. No inheritance hierarchy. Just Ruby doing its job.

### 3. Excessive Namespacing

```ruby
module Api
  module V1
    class ConversationsController < BaseController
```

API versioning is reasonable foresight, but `Api::V1::BaseController` inheriting from `ActionController::API` creates an unnecessary abstraction. The concern-based approach for authentication is fine, but you do not need a base controller class for three controllers.

---

## Improvements Needed

### 1. Simplify the ApiKey Model

The model is mostly good, but `has_secure_token` combined with manual token generation is confusing. Pick one approach.

```ruby
# Before: Confusing dual approach
has_secure_token :token, length: 32  # Not actually used
def self.generate_for(user, name:)
  raw_token = "#{TOKEN_PREFIX}#{SecureRandom.hex(24)}"
  # ... manual token handling
end
```

```ruby
# After: Clear, single approach
class ApiKey < ApplicationRecord
  TOKEN_PREFIX = "hx_"

  belongs_to :user

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true

  def self.generate_for(user, name:)
    raw_token = "#{TOKEN_PREFIX}#{SecureRandom.hex(24)}"

    key = create!(
      user: user,
      name: name,
      token_digest: BCrypt::Password.create(raw_token),
      token_prefix: raw_token[0, 8]
    )

    key.define_singleton_method(:raw_token) { raw_token }
    key
  end

  def self.authenticate(token)
    return nil if token.blank?
    where(token_prefix: token[0, 8]).find { |k| BCrypt::Password.new(k.token_digest) == token }
  end
end
```

### 2. The Transcript Method Belongs in Chat

The `transcript_for_api` method in the spec is good Rails thinking - put data formatting in the model. But `format_message_for_transcript` and `message_author_name` should be private methods, not separate concerns.

### 3. Simplify the Controller Structure

You do not need `Api::V1::BaseController`. Just include the concern directly.

```ruby
# Before
module Api
  module V1
    class BaseController < ActionController::API
      include ApiAuthentication
      # ...
    end

    class ConversationsController < BaseController
      # ...
    end
  end
end

# After
module Api
  module V1
    class ConversationsController < ActionController::API
      include ApiAuthentication

      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Not found" }, status: :not_found
      end

      # ... actual actions
    end
  end
end
```

When you have 10 API controllers sharing identical rescue handlers, extract a base class. With 2-3 controllers, it is premature.

### 4. The Whiteboard Update Needs Simpler Conflict Handling

```ruby
# Before: Manual revision checking
if params[:expected_revision].present? && whiteboard.revision != params[:expected_revision].to_i
  return render json: { error: "conflict", ... }, status: :conflict
end
```

This is fine, but consider using Rails' built-in optimistic locking with `lock_version`. It handles all of this automatically.

```ruby
# Migration
add_column :whiteboards, :lock_version, :integer, default: 0

# Model - nothing needed, Rails handles it

# Controller
def update
  whiteboard = current_api_account.whiteboards.find(params[:id])
  whiteboard.update!(content: params[:content])
  render json: { whiteboard: whiteboard.slice(:id, :lock_version) }
rescue ActiveRecord::StaleObjectError
  render json: { error: "Whiteboard was modified" }, status: :conflict
end
```

---

## What Works Well

1. **Database design is pragmatic.** Storing token digests, using prefix indexing for fast lookups, tracking usage metadata - all sensible decisions.

2. **The API surface is clean.** REST resources, standard HTTP methods, JSON responses. No GraphQL astronaut architecture.

3. **Security considerations are appropriate.** BCrypt hashing, one-time token display, user scoping - these are the right instincts.

4. **The controllers use scopes correctly.** `current_api_account.chats.kept.active.latest.limit(100)` is idiomatic Rails.

5. **The summary cooldown prevents abuse.** Simple rate limiting through timestamps, not complex infrastructure.

6. **Using `update_columns` for touch_usage!** Correctly avoids unnecessary callbacks and validations for metadata updates.

---

## Recommended Simplified Scope

For V1, implement only:

1. **ApiKey model** - simplified, no OAuth flow
2. **ApiKeysController** - browser-based management only (index, create, destroy)
3. **Api::V1::ConversationsController** - index, show, create_message
4. **Api::V1::WhiteboardsController** - index, show, update
5. **Summary generation** - as a simple method in the Chat model

This gives you:
- ~300 lines of Ruby (not 900)
- ~100 lines of Svelte (2 pages, not 5)
- Zero state machines
- Zero polling infrastructure
- A working API you can iterate on

Add the OAuth CLI flow in V2 when you have evidence someone wants it.

---

## The Bottom Line

This specification suffers from solving tomorrow's problems today. The OAuth flow, the prompt class hierarchy, the excessive controller nesting - these are all reasonable ideas for a mature API with many consumers. But you are building an API for Claude Code. Start simple. Ship it. Add complexity when you have actual pain points, not imagined ones.

The Rails Way is not about anticipating every future need. It is about building what you need now, building it well, and trusting that you can refactor later. Your future self can add OAuth in an afternoon. Your present self should ship a working API this week.

---

*"Simplicity is the ultimate sophistication." - Leonardo da Vinci, frequently quoted by Rails developers deleting service objects*
