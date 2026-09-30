# DHH Review: GitHub Integration Spec (260201-01a)

## Overall Assessment

This is a well-structured spec that closely follows the existing Oura integration pattern -- which is exactly what you should do. The model is fat, the controller is skinny, the concern extracts API plumbing cleanly, and there are no service objects in sight. That said, there are a handful of places where the spec drifts from the established pattern or introduces unnecessary complexity. Let me be specific.

## Critical Issues

### 1. The `set_account` method is a red flag

```ruby
def set_account
  @account = Current.user.accounts.find(session[:current_account_id] || Current.user.accounts.first.id)
end
```

The spec itself admits uncertainty here with "Check how the existing codebase resolves the current account." This is not something to leave ambiguous in an implementation spec. The Oura controller does not have this problem because it scopes through `Current.user` directly. Before writing any code, find the existing `current_account` helper (there almost certainly is one) and use it. Do not invent a new pattern for resolving the current account.

### 2. The job does double duty -- dispatch and execute

```ruby
def perform(github_integration_id = nil)
  if github_integration_id
    GithubIntegration.find(github_integration_id).sync_commits!
  else
    GithubIntegration.needs_sync.find_each do |integration|
      SyncGithubCommitsJob.perform_later(integration.id)
    end
  end
end
```

A single job that behaves as both a dispatcher and a worker depending on whether an argument is present is a code smell. The Oura integration likely has the same pattern and it was wrong there too. Make two things: the recurring job dispatches, and the per-integration job executes. Or better yet, just have the recurring schedule call a class method on the model:

```ruby
# In the recurring schedule, call:
GithubIntegration.sync_all_due!

# In the model:
def self.sync_all_due!
  needs_sync.find_each { |i| SyncGithubCommitsJob.perform_later(i.id) }
end
```

Then `SyncGithubCommitsJob#perform` always takes an ID and always does one thing. Single responsibility.

## Improvements Needed

### 3. The `connect()` function builds a form manually in JavaScript

```javascript
function connect() {
  const form = document.createElement('form');
  form.method = 'POST';
  form.action = '/github_integration';
  // ... manually creating CSRF input, appending to body, submitting
}
```

This is copied from the Oura integration and it was ugly there too. But if this is the established pattern in the codebase for handling OAuth redirects that need a POST (to avoid Inertia intercepting the redirect), then keep it consistent. Just know that it is a workaround, not a pattern to be proud of. Add a comment explaining *why* this exists -- that Inertia's router would intercept the redirect otherwise.

### 4. The `select_repo` and `save_repo` actions add complexity the Oura flow does not have

This is the only genuinely new piece of controller logic beyond what Oura established. It is justified -- GitHub requires repo selection, Oura does not. But be aware this adds a second page, a second render, and a second action that the Oura pattern did not need. The implementation is clean enough. No objections to the approach itself.

### 5. Guard clauses are inconsistent

Some actions check `@integration` presence with early returns, others use safe navigation:

```ruby
# Style A - early return
redirect_to github_integration_path and return unless @integration

# Style B - safe navigation
@integration&.disconnect!
```

Pick one style and stick with it. For `destroy`, if there is no integration, you should redirect with an alert rather than silently doing nothing. The Oura controller uses `&.disconnect!` too, so this is inherited imperfection. For a new integration, do better:

```ruby
def destroy
  redirect_to github_integration_path, alert: "No integration found" and return unless @integration
  @integration.disconnect!
  redirect_to github_integration_path, notice: "GitHub disconnected"
end
```

### 6. The concern is doing too much HTTP plumbing

The `GithubApi` concern has a lot of raw `Net::HTTP` code. This is fine for an MVP and matches the Oura pattern. But if you find yourself writing a third integration with the same `Net::HTTP.start(uri.hostname, uri.port, use_ssl: true)` boilerplate, extract an `ApiClient` module or use `Faraday`. For now, this passes.

### 7. `parse_token_response` handles GitHub's quirk -- document why

```ruby
def parse_token_response(body)
  JSON.parse(body)
rescue JSON::ParserError
  URI.decode_www_form(body).to_h
end
```

This silently handles two different response formats. The comment in the spec explains it but the code itself would not. Since comments are a code smell, rename the method to something that communicates intent: `parse_token_response_json_or_form_encoded`.

Actually, no. Just set the `Accept: application/json` header on the token request and you will always get JSON back. Then you do not need the fallback at all:

```ruby
def exchange_code!(code:, redirect_uri:)
  uri = URI(GITHUB_TOKEN_URL)
  request = Net::HTTP::Post.new(uri)
  request["Accept"] = "application/json"
  request.set_form_data(client_id: ..., client_secret: ..., code: code, redirect_uri: redirect_uri)

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
  data = JSON.parse(response.body)
  # ...
end
```

Eliminate the ambiguity rather than handling it.

## What Works Well

- **Following the Oura pattern faithfully.** This is the single most important thing the spec gets right. Consistency across integrations is worth more than local perfection.
- **Fat model, skinny controller.** `sync_commits!`, `commits_context`, `disconnect!` -- all in the model where they belong. The controller just orchestrates.
- **The concern extraction.** `GithubApi` keeps API plumbing out of the model's business logic. Clean separation.
- **The migration is simple and correct.** No unnecessary columns, proper defaults, unique index on `account_id`.
- **Context injection is minimal.** Two lines added to existing methods. No over-engineering.
- **The Svelte components are clean.** Good use of `$props()`, `$state()`, `$derived()`. The repo selection page with client-side filtering is a nice touch that avoids unnecessary server round-trips.
- **`needs_sync` scope.** Elegant, declarative, and avoids syncing too frequently.

## Summary

This spec is about 85% there. The core architecture is sound and follows established patterns. Fix the account resolution, clean up the job's dual responsibility, set the Accept header on the token exchange to eliminate the format ambiguity, and tighten up the guard clause consistency. Then ship it.
