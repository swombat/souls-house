# DHH Review: GitHub Integration Spec v2

## Overall Assessment

This is solid work. Every issue from the first review was addressed correctly: `current_account` is in place, the job is single-responsibility with dispatch on the model, the Accept header eliminates the format ambiguity, and guard clauses are consistent. The spec is ready to build. I have a few minor observations but nothing that should block implementation.

## Minor Issues

### 1. The callback guard clause style diverges from Oura

The Oura controller uses multi-line `unless`/`return` blocks in `callback`. The v2 spec uses one-liner `redirect_to ... and return` style throughout, including callback:

```ruby
redirect_to github_integration_path, alert: "Authorization was denied" and return if params[:error]
```

This is fine as a stylistic choice, and arguably more concise. But be aware of Ruby's operator precedence here. `and return` binds loosely, so this works, but it reads differently from the Oura controller's explicit block style:

```ruby
if params[:error]
  redirect_to oura_integration_path, alert: "Authorization was denied"
  return
end
```

Pick whichever you prefer but be consistent across both integration controllers. If you are going to use the one-liner style in GitHub, refactor Oura to match (or vice versa). Two OAuth controllers in the same app using different guard clause styles is a maintenance annoyance.

### 2. `save_repo` does not validate the repo name

```ruby
def save_repo
  @integration.update!(repository_full_name: params[:repository_full_name])
end
```

A user can POST any string as `repository_full_name`. At minimum, add a format validation on the model:

```ruby
validates :repository_full_name, format: { with: /\A[\w\-\.]+\/[\w\-\.]+\z/ }, allow_nil: true
```

This is not paranoia -- it is a parameter that gets interpolated into an API URL (`/repos/#{repository_full_name}/commits`). Validate it.

### 3. The `sync` action checks two conditions inline

```ruby
redirect_to github_integration_path, alert: "No repository linked" and return unless @integration&.connected? && @integration.repository_full_name.present?
```

That line is doing a lot of work. Consider extracting a `ready_to_sync?` method on the model:

```ruby
def ready_to_sync?
  connected? && repository_full_name.present?
end
```

Then the controller reads:

```ruby
redirect_to github_integration_path, alert: "No repository linked" and return unless @integration&.ready_to_sync?
```

### 4. `disconnect!` clears `github_username` -- Oura does not clear its equivalent

Oura's `disconnect!` clears tokens and health data but does not clear user-identifying info. The GitHub version clears `github_username`. This is a defensible choice (the username is tied to the token), but note the inconsistency. If you clear `github_username` on disconnect, consider whether Oura should clear its equivalent too, or document why they differ.

## What Works Well

- **Every v1 issue addressed cleanly.** No over-correction, no new abstractions introduced to solve simple problems.
- **`sync_all_due!` on the model is textbook Rails.** The recurring schedule calls a class method, the class method dispatches jobs. Simple, testable, no dual-purpose jobs.
- **The concern is well-contained.** `GithubApi` handles all HTTP plumbing, the model handles all business logic. Clean boundary.
- **Repo selection flow is minimal.** One GET to render, one POST to save. No wizard, no state machine. Just what is needed.
- **The Svelte components are clean and idiomatic.** Good use of `$derived` for filtering. The native form POST workaround has a comment explaining why it exists.
- **The migration is tight.** No speculative columns, proper constraints.

## Verdict

Ship it. Fix the repo name validation before you do -- that is the only thing I would call a genuine issue. The rest are style observations you can address during implementation or ignore entirely.
