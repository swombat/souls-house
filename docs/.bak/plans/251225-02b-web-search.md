# Web Search Tool Implementation Plan

**Date**: 2025-12-25
**Feature**: Add web search capability via SearXNG
**Status**: Ready for implementation
**Revision**: 2b (incorporates DHH feedback)

## Executive Summary

Add a `WebSearchTool` that allows the AI to search the web using our self-hosted SearXNG instance. This extends the existing web access feature by providing search alongside the existing URL fetch capability. A single "web access" checkbox enables both tools.

The implementation involves:
1. Renaming `can_fetch_urls` to `web_access` across the codebase
2. Creating a new `WebSearchTool` following the existing `WebFetchTool` pattern
3. Configuring the SearXNG URL via Rails credentials
4. Updating `available_tools` to return both tools when web access is enabled

## Architecture Overview

```
User enables "Web access" checkbox
         |
         v
Chat.web_access = true
         |
         v
Chat#available_tools returns [WebFetchTool, WebSearchTool]
         |
         v
AiResponseJob configures both tools for the conversation
         |
         v
AI can call web_search(query) -> SearXNG -> returns URLs with snippets
AI can call web_fetch(url) -> fetch page content
```

## Implementation Steps

### Step 1: Database Migration

Rename `can_fetch_urls` to `web_access` for clarity since it now controls multiple tools.

- [ ] Create migration to rename column

```ruby
# db/migrate/XXXXXX_rename_can_fetch_urls_to_web_access.rb
class RenameCanFetchUrlsToWebAccess < ActiveRecord::Migration[8.0]
  def change
    rename_column :chats, :can_fetch_urls, :web_access
  end
end
```

### Step 2: Add SearXNG Configuration

Store the SearXNG URL in Rails credentials.

- [ ] Add SearXNG URL to credentials structure

Add to `config/credentials.yml.enc`:
```yaml
searxng:
  url: https://searxng.granttree.co.uk/search
```

Add the same to `config/credentials/development.yml.enc` for local development.

### Step 3: Create WebSearchTool

- [ ] Create `/app/tools/web_search_tool.rb`

```ruby
require "net/http"
require "json"

class WebSearchTool < RubyLLM::Tool

  RESULT_LIMIT = 10
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 15

  description "Search the web for information. Returns URLs with titles and snippets. Use web_fetch to read full content from promising results."

  param :query, type: :string, desc: "The search query", required: true

  def execute(query:)
    response = fetch_results(query)

    return error_response("HTTP #{response.code}: #{response.message}", query) unless response.is_a?(Net::HTTPSuccess)

    parse_results(response.body, query)
  rescue JSON::ParserError
    error_response("Invalid response from search service", query)
  rescue => e
    error_response(e.message, query)
  end

  private

  def fetch_results(query)
    uri = build_uri(query)

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                    open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "HelixKit/1.0"
      http.request(request)
    end
  end

  def build_uri(query)
    uri = URI(searxng_url)
    uri.query = URI.encode_www_form(q: query, format: "json")
    uri
  end

  def parse_results(body, query)
    data = JSON.parse(body)

    {
      query: query,
      results: data["results"].first(RESULT_LIMIT).map { |r| format_result(r) },
      total_results: data["number_of_results"]
    }
  end

  def format_result(result)
    {
      url: result["url"],
      title: result["title"],
      snippet: result["content"]
    }
  end

  def error_response(message, query)
    { error: message, query: query }
  end

  def searxng_url
    Rails.application.credentials.dig(:searxng, :url) ||
      raise("SearXNG URL not configured. Add searxng.url to Rails credentials.")
  end

end
```

**Design Notes:**
- Returns structured results with URL, title, and snippet
- AI can then use `WebFetchTool` to get full content from interesting URLs
- Fixed limit of 10 results to avoid overwhelming context
- Consistent error handling with `WebFetchTool` (includes both error message AND query)
- Constants for timeouts and limits
- Small, focused methods following single responsibility

### Step 4: Update Chat Model

- [ ] Update `json_attributes` to use `web_access` (rename `can_fetch_urls` to `web_access`)
- [ ] Update `available_tools` to return both tools

```ruby
class Chat < ApplicationRecord
  # In json_attributes, rename can_fetch_urls to web_access

  def available_tools
    return [] unless web_access?
    [WebFetchTool, WebSearchTool]
  end
end
```

### Step 5: Update ChatsController

- [ ] Update `chat_params` to permit `web_access`

```ruby
def chat_params
  params.fetch(:chat, {})
    .permit(:model_id, :web_access)
end
```

### Step 6: Update Frontend Components

- [ ] Update `/app/frontend/pages/chats/show.svelte`

Change all references from `can_fetch_urls` to `web_access`:

```svelte
<!-- In toggleWebAccess function -->
function toggleWebAccess() {
  if (!chat) return;

  router.patch(
    `/accounts/${account.id}/chats/${chat.id}`,
    {
      chat: { web_access: !chat.web_access },
    },
    // ... rest unchanged
  );
}

<!-- In the checkbox -->
<input
  type="checkbox"
  checked={chat.web_access}
  onchange={toggleWebAccess}
  class="..." />
```

- [ ] Update `/app/frontend/pages/chats/new.svelte`

Change state variable and form field:

```svelte
<script>
  // Change variable name for clarity
  let webAccess = $state(false);

  let createForm = useForm({
    chat: {
      model_id: selectedModel,
      web_access: webAccess,
    },
    message: '',
  });

  function startChat() {
    // ...
    $createForm.chat.web_access = webAccess;
    formData.append('chat[web_access]', webAccess.toString());
    // ...
  }
</script>

<!-- In template, bind to webAccess instead of canFetchUrls -->
<input
  type="checkbox"
  bind:checked={webAccess}
  class="..." />
```

### Step 7: Update Tests

- [ ] Update Chat model tests

```ruby
# test/models/chat_test.rb

test "web_access defaults to false" do
  chat = Chat.create!(account: @account)
  assert_equal false, chat.web_access
end

test "available_tools returns empty array when web access disabled" do
  chat = Chat.create!(account: @account, web_access: false)
  assert_empty chat.available_tools
end

test "available_tools includes both tools when web access enabled" do
  chat = Chat.create!(account: @account, web_access: true)
  assert_includes chat.available_tools, WebFetchTool
  assert_includes chat.available_tools, WebSearchTool
  assert_equal 2, chat.available_tools.length
end

test "web_access can be set on create" do
  chat = Chat.create!(account: @account, web_access: true)
  assert chat.web_access
end

test "web_access can be updated" do
  chat = Chat.create!(account: @account, web_access: false)
  assert_not chat.web_access

  chat.update!(web_access: true)
  assert chat.web_access
end
```

- [ ] Add WebSearchTool unit tests

```ruby
# test/tools/web_search_tool_test.rb
require "test_helper"
require "webmock/minitest"

class WebSearchToolTest < ActiveSupport::TestCase
  setup do
    @tool = WebSearchTool.new
  end

  test "returns search results for valid query" do
    stub_searxng_success

    result = @tool.execute(query: "ruby on rails")

    assert_equal "ruby on rails", result[:query]
    assert_equal 2, result[:results].length
    assert_equal "https://rubyonrails.org", result[:results].first[:url]
  end

  test "limits results to configured maximum" do
    stub_searxng_with_many_results(15)

    result = @tool.execute(query: "test")

    assert_equal 10, result[:results].length
  end

  test "returns error with query for failed request" do
    stub_request(:get, /searxng/).to_return(status: 500, body: "", headers: {})

    result = @tool.execute(query: "test")

    assert_match(/500/, result[:error])
    assert_equal "test", result[:query]
  end

  test "returns error for timeout" do
    stub_request(:get, /searxng/).to_timeout

    result = @tool.execute(query: "test")

    assert result[:error].present?
    assert_equal "test", result[:query]
  end

  test "handles empty results" do
    stub_searxng_empty

    result = @tool.execute(query: "obscure query")

    assert_equal [], result[:results]
    assert_equal 0, result[:total_results]
  end

  test "handles invalid JSON response" do
    stub_request(:get, /searxng/)
      .to_return(status: 200, body: "not json", headers: {})

    result = @tool.execute(query: "test")

    assert_equal "Invalid response from search service", result[:error]
    assert_equal "test", result[:query]
  end

  test "raises error when SearXNG URL not configured" do
    Rails.application.credentials.stubs(:dig).with(:searxng, :url).returns(nil)

    assert_raises(RuntimeError) { @tool.send(:searxng_url) }
  end

  private

  def stub_searxng_success
    stub_request(:get, /searxng/)
      .to_return(status: 200, body: searxng_response(2).to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  def stub_searxng_with_many_results(count)
    stub_request(:get, /searxng/)
      .to_return(status: 200, body: searxng_response(count).to_json)
  end

  def stub_searxng_empty
    stub_request(:get, /searxng/)
      .to_return(status: 200, body: { query: "test", number_of_results: 0, results: [] }.to_json)
  end

  def searxng_response(count)
    {
      query: "ruby on rails",
      number_of_results: count * 100,
      results: count.times.map do |i|
        { url: "https://example#{i}.com".gsub("example0", "rubyonrails"), title: "Result #{i}", content: "Content #{i}" }
      end
    }
  end
end
```

- [ ] Update integration tests to use `web_access`

All existing tests in `test/integration/chat_tools_flow_test.rb` and `test/controllers/chats_controller_test.rb` need `can_fetch_urls` replaced with `web_access`.

- [ ] Update job tests

Tests in `test/jobs/ai_response_job_test.rb` that reference `can_fetch_urls` need updating.

## File Changes Summary

| File | Change |
|------|--------|
| `db/migrate/XXXXXX_rename_can_fetch_urls_to_web_access.rb` | New migration |
| `app/tools/web_search_tool.rb` | New tool |
| `app/models/chat.rb` | Rename in `json_attributes`, update `available_tools` |
| `app/controllers/chats_controller.rb` | Update `chat_params` |
| `app/frontend/pages/chats/show.svelte` | Rename `can_fetch_urls` to `web_access` |
| `app/frontend/pages/chats/new.svelte` | Rename `canFetchUrls` to `webAccess` |
| `test/models/chat_test.rb` | Update tests |
| `test/tools/web_search_tool_test.rb` | New test file |
| `test/controllers/chats_controller_test.rb` | Update field name |
| `test/integration/chat_tools_flow_test.rb` | Update field name |
| `test/jobs/ai_response_job_test.rb` | Update field name |
| `config/credentials.yml.enc` | Add `searxng.url` |
| `config/credentials/development.yml.enc` | Add `searxng.url` |

## Configuration

### Production
SearXNG is deployed at `https://searxng.granttree.co.uk` via Kamal accessory. Add to credentials:

```yaml
searxng:
  url: https://searxng.granttree.co.uk/search
```

### Development
Add the same URL to `config/credentials/development.yml.enc`. This is the Rails way - credentials for both environments, no ENV fallbacks.

## Edge Cases and Error Handling

1. **SearXNG unavailable**: Tool returns `{ error: "...", query: "..." }`, AI handles gracefully
2. **Empty results**: Returns empty array, AI can try different query or inform user
3. **Timeout**: 15-second timeout, returns error with query context
4. **Invalid JSON response**: Returns error message with query
5. **Missing configuration**: Raises clear error at runtime - deployment issue, not runtime fallback
6. **Rate limiting**: Disabled on our SearXNG instance, not a concern

## Testing Strategy

1. **Unit tests** for `WebSearchTool` with mocked HTTP responses and helper methods
2. **Model tests** for `Chat#available_tools` with both tools
3. **Controller tests** for `web_access` parameter handling
4. **Integration tests** verifying the full flow remains functional

Run full test suite: `rails test`

## Changes from Revision 2a

Based on DHH's feedback:

1. **Removed `num_results` parameter** - YAGNI violation. Fixed `RESULT_LIMIT = 10` constant instead.
2. **Moved `require` statements to top of file** - not inside the execute method.
3. **Removed ENV fallback** - credentials only, raises error if not configured.
4. **Fixed error response consistency** - all errors now include both `error` and `query` keys.
5. **Removed `rename_index` from migration** - just rename the column, index may not exist.
6. **Refactored into smaller methods** - extracted `fetch_results`, `build_uri`, `parse_results`, `format_result`, `error_response`.
7. **Added constants for timeouts** - `OPEN_TIMEOUT`, `READ_TIMEOUT`, `RESULT_LIMIT`.
8. **Simplified tests** - removed tests for `num_results` parameter, extracted stub helpers.
