# DHH Review: AI-Friendly JSON API Spec v2

**Reviewer:** DHH (channeled)
**Date:** January 15, 2026
**Verdict:** Ship it.

---

## Overall Assessment

This is a dramatic improvement. You listened to the feedback and made the hard cuts. The OAuth flow is gone. The separate prompt class is gone. The unnecessary base controller is gone. What remains is a focused, Rails-worthy implementation that could ship this week.

The spec now embodies what Rails is about: get something working, get it in front of users, and iterate from there. You are not building an enterprise API platform. You are building a simple integration for AI tools. The code reflects that reality.

---

## What You Got Right

### 1. Browser-Based Key Management Only

No OAuth dance. No polling endpoints. No approval pages. A user logs in, clicks "Create Key," copies the token, and pastes it into their CLI tool. Done.

This is exactly right. The OAuth flow was solving a problem you do not have yet. When Claude Code users are screaming for it, build it then. Not before.

### 2. Summary Generation in the Model

```ruby
def generate_summary!
  return summary unless summary_stale?
  # ...
end
```

This belongs in Chat. The model knows about its messages. The model knows about its summary. The model can decide when to regenerate. No ceremony, no separate class, no over-abstraction.

The use of the existing `Prompt` class with a simple template is the Rails way. You already have the infrastructure. Use it.

### 3. Concern Over Inheritance

```ruby
class ConversationsController < ActionController::API
  include ApiAuthentication
```

Including a concern directly is cleaner than inheriting from a base class when you only have two controllers. Extract `Api::V1::BaseController` when you have ten API controllers, not two.

### 4. Rails Built-in Optimistic Locking

```ruby
rescue_from ActiveRecord::StaleObjectError do
  render json: { error: "Whiteboard was modified by another user" }, status: :conflict
end
```

`lock_version` is a Rails feature. Use it. Do not reinvent conflict detection. This is textbook Rails.

### 5. The Line Count

~400 lines total. That is a feature you can ship, test, and maintain. The previous spec was headed toward 800+ lines before you had a single user. Restraint is a feature.

---

## Minor Issues to Address

### 1. The Summary Generation Method Has a Bug

The `generate_summary_from_llm` method builds a transcript but never passes it to the prompt:

```ruby
def generate_summary_from_llm
  transcript = messages.where(role: %w[user assistant])
                       .order(:created_at)
                       .limit(20)
                       .map { |m| "#{m.role.titleize}: #{m.content.to_s.truncate(300)}" }
                       .join("\n")

  return nil if transcript.blank?

  prompt = Prompt.new(model: Prompt::LIGHT_MODEL, template: "generate_summary")
  response = prompt.execute_to_string  # <-- Where does transcript go?
```

Looking at your existing `generate_title` prompt, you pass variables through the ERB template. The fix:

```ruby
def generate_summary_from_llm
  transcript = messages.where(role: %w[user assistant])
                       .order(:created_at)
                       .limit(20)
                       .map { |m| "#{m.role.titleize}: #{m.content.to_s.truncate(300)}" }
                       .join("\n")

  return nil if transcript.blank?

  prompt = Prompt.new(model: Prompt::LIGHT_MODEL, template: "generate_summary")
  prompt.instance_variable_set(:@args, { messages: transcript })
  response = prompt.execute_to_string
  response&.squish&.truncate_words(SUMMARY_MAX_WORDS)
rescue StandardError => e
  Rails.logger.error "Summary generation failed: #{e.message}"
  nil
end
```

Better yet, looking at how `render_template` works, just set `@args` in the initializer or add a method. But honestly, this is implementation detail - the spec is about design, not debugging.

### 2. The Prompt Template Variable Name

Your template uses `<%= messages %>` but the existing codebase pattern (see `generate_title/user.prompt.erb`) iterates over messages. Keep consistent:

```erb
Summarize this conversation:

<% messages.each do |line| %>
- <%= line %>
<% end %>
```

Or just pass the formatted transcript as a single string variable. Either works.

### 3. BCrypt for Token Hashing is Overkill

You are using BCrypt, which is intentionally slow for password hashing. For API tokens, you want fast verification. Use SHA256:

```ruby
def self.generate_for(user, name:)
  raw_token = "#{TOKEN_PREFIX}#{SecureRandom.hex(24)}"

  key = create!(
    user: user,
    name: name,
    token_digest: Digest::SHA256.hexdigest(raw_token),
    token_prefix: raw_token[0, 8]
  )

  key.define_singleton_method(:raw_token) { raw_token }
  key
end

def self.authenticate(token)
  return nil if token.blank?
  find_by(token_digest: Digest::SHA256.hexdigest(token))
end
```

This is simpler AND faster. You do not need the prefix-based lookup optimization with SHA256 since lookup is a single indexed query.

Actually, keep the prefix for display purposes (`hx_abc1...`), but use it only for UI, not for authentication filtering.

### 4. Consider `update!` vs `update` in `touch_usage!`

```ruby
def touch_usage!(ip_address)
  update_columns(last_used_at: Time.current, last_used_ip: ip_address)
end
```

`update_columns` bypasses validations and callbacks, which is correct here - you want speed. Good call.

---

## What I Would Cut (If Pressed for Time)

If you need to ship faster, consider these simplifications:

1. **Skip summaries entirely for v1.** Just return the title. Add summaries when users ask for them.

2. **Skip `last_used_at` tracking.** Nice to have, not essential. Add it in v1.1.

3. **Skip the Svelte components initially.** A plain Rails view with ERB and a form would work fine for key management. Inertia is great, but if you already have ERB forms in your app, use them.

None of these are required cuts. The spec is already lean enough. But if someone said "ship it today," these are the knobs to turn.

---

## The Test Strategy is Solid

Your test examples are focused and pragmatic:

```ruby
test "generates key with correct prefix" do
  key = ApiKey.generate_for(@user, name: "Test Key")
  assert key.raw_token.start_with?("hx_")
end
```

Test the behavior that matters. Do not test Rails. Do not test BCrypt. Test YOUR code.

---

## Final Verdict

**Ship it.**

This spec represents the right level of ambition for a v1. It will work. It will be maintainable. It follows Rails conventions. It does not try to solve problems you do not have yet.

The summary generation bug is a minor implementation issue, not a design flaw. Fix it during implementation.

The BCrypt vs SHA256 choice is a judgment call - BCrypt is fine, SHA256 is better. Either works.

Everything else is solid. Build it, ship it, iterate.

---

## Checklist Before Implementation

- [ ] Fix the transcript variable passing in `generate_summary_from_llm`
- [ ] Consider switching to SHA256 for token hashing
- [ ] Ensure the prompt template matches the variable names you are passing
- [ ] Run `rails test` after implementation
- [ ] Manual test with curl: create key, list conversations, post message

When this ships, you will have a working API in ~400 lines that Claude Code can use to interact with your app. That is the goal. Everything else is premature optimization.

Good work on the revision.
