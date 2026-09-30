# Web Search Tool Implementation Plan

**Date**: 2025-12-25
**Feature**: Add web search capability via SearXNG
**Status**: Ready for implementation

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
    rename_index :chats, :index_chats_on_can_fetch_urls, :index_chats_on_web_access
  end
end
```

### Step 2: Add SearXNG Configuration

Store the SearXNG URL in Rails credentials, following the existing pattern for API keys.

- [ ] Add SearXNG URL to credentials structure

Add to `config/credentials.yml.enc`:
```yaml
searxng:
  url: https://searxng.granttree.co.uk
```

For development, developers can either:
- Point to production SearXNG (simplest)
- Run SearXNG locally via Docker on port 8888

### Step 3: Create WebSearchTool

- [ ] Create `/app/tools/web_search_tool.rb`

```ruby
class WebSearchTool < RubyLLM::Tool

  description "Search the web for information. Returns a list of URLs with titles and snippets. Use web_fetch to read full content from promising results."

  param :query, type: :string, desc: "The search query", required: true
  param :num_results, type: :integer, desc: "Number of results to return (default: 10, max: 20)", required: false

  def execute(query:, num_results: 10)
    require "net/http"
    require "json"

    num_results = [[num_results.to_i, 1].max, 20].min

    uri = URI(searxng_url)
    uri.query = URI.encode_www_form(q: query, format: "json")

    response = Net::HTTP.start(uri.host, uri.port,
                              use_ssl: uri.scheme == "https",
                              open_timeout: 10,
                              read_timeout: 15) do |http|
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "HelixKit/1.0"
      http.request(request)
    end

    unless response.is_a?(Net::HTTPSuccess)
      return { error: "Search failed: HTTP #{response.code}" }
    end

    data = JSON.parse(response.body)
    results = data["results"].first(num_results).map do |result|
      {
        url: result["url"],
        title: result["title"],
        snippet: result["content"]
      }
    end

    {
      query: query,
      results: results,
      total_results: data["number_of_results"]
    }
  rescue JSON::ParserError
    { error: "Invalid response from search service" }
  rescue => e
    { error: e.message }
  end

  private

  def searxng_url
    Rails.application.credentials.dig(:searxng, :url) ||
      ENV["SEARXNG_URL"] ||
      "https://searxng.granttree.co.uk/search"
  end

end
```

**Design Notes:**
- Returns structured results with URL, title, and snippet
- AI can then use `WebFetchTool` to get full content from interesting URLs
- Limits results to avoid overwhelming context
- Uses same timeout/error handling pattern as `WebFetchTool`

### Step 4: Update Chat Model

- [ ] Update `json_attributes` to use `web_access`
- [ ] Update `available_tools` to return both tools

```ruby
class Chat < ApplicationRecord
  # ... existing code ...

  json_attributes :title_or_default, :model_id, :model_name, :ai_model_name,
                  :updated_at_formatted, :updated_at_short, :message_count, :web_access do |hash, options|
    if options&.dig(:as) == :sidebar_json
      hash.slice!("id", "title_or_default", "updated_at_short")
    end
    hash
  end

  # ... existing code ...

  def available_tools
    return [] unless web_access?
    [WebFetchTool, WebSearchTool]
  end

  # ... rest of model ...
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
      web_access: webAccess,  // renamed
    },
    message: '',
  });

  function startChat() {
    // ...
    $createForm.chat.web_access = webAccess;  // renamed
    formData.append('chat[web_access]', webAccess.toString());  // renamed
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
    @searxng_url = "https://searxng.granttree.co.uk/search"
  end

  test "returns search results for valid query" do
    stub_request(:get, /searxng\.granttree\.co\.uk/)
      .to_return(
        status: 200,
        body: {
          query: "ruby on rails",
          number_of_results: 1000,
          results: [
            { url: "https://rubyonrails.org", title: "Ruby on Rails", content: "A web framework" },
            { url: "https://guides.rubyonrails.org", title: "Rails Guides", content: "Documentation" }
          ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = @tool.execute(query: "ruby on rails")

    assert_equal "ruby on rails", result[:query]
    assert_equal 2, result[:results].length
    assert_equal "https://rubyonrails.org", result[:results][0][:url]
    assert_equal "Ruby on Rails", result[:results][0][:title]
    assert_equal "A web framework", result[:results][0][:snippet]
  end

  test "limits results to num_results parameter" do
    stub_request(:get, /searxng\.granttree\.co\.uk/)
      .to_return(
        status: 200,
        body: {
          query: "test",
          number_of_results: 100,
          results: 15.times.map { |i| { url: "https://example#{i}.com", title: "Result #{i}", content: "Content" } }
        }.to_json
      )

    result = @tool.execute(query: "test", num_results: 5)
    assert_equal 5, result[:results].length
  end

  test "caps num_results at 20" do
    stub_request(:get, /searxng\.granttree\.co\.uk/)
      .to_return(
        status: 200,
        body: {
          query: "test",
          number_of_results: 100,
          results: 25.times.map { |i| { url: "https://example#{i}.com", title: "Result #{i}", content: "Content" } }
        }.to_json
      )

    result = @tool.execute(query: "test", num_results: 50)
    assert_equal 20, result[:results].length
  end

  test "returns error for failed request" do
    stub_request(:get, /searxng\.granttree\.co\.uk/)
      .to_return(status: 500)

    result = @tool.execute(query: "test")
    assert result[:error].include?("500")
  end

  test "returns error for timeout" do
    stub_request(:get, /searxng\.granttree\.co\.uk/)
      .to_timeout

    result = @tool.execute(query: "test")
    assert result[:error].present?
  end

  test "handles empty results" do
    stub_request(:get, /searxng\.granttree\.co\.uk/)
      .to_return(
        status: 200,
        body: { query: "obscure query", number_of_results: 0, results: [] }.to_json
      )

    result = @tool.execute(query: "obscure query")
    assert_equal [], result[:results]
    assert_equal 0, result[:total_results]
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
| `app/models/chat.rb` | Update `json_attributes`, `available_tools` |
| `app/controllers/chats_controller.rb` | Update `chat_params` |
| `app/frontend/pages/chats/show.svelte` | Rename `can_fetch_urls` to `web_access` |
| `app/frontend/pages/chats/new.svelte` | Rename `canFetchUrls` to `webAccess` |
| `test/models/chat_test.rb` | Update tests |
| `test/tools/web_search_tool_test.rb` | New test file |
| `test/controllers/chats_controller_test.rb` | Update field name |
| `test/integration/chat_tools_flow_test.rb` | Update field name |
| `test/jobs/ai_response_job_test.rb` | Update field name |
| `config/credentials.yml.enc` | Add `searxng.url` |

## Configuration

### Production
SearXNG is deployed at `https://searxng.granttree.co.uk` via Kamal accessory. Add to credentials:

```yaml
searxng:
  url: https://searxng.granttree.co.uk/search
```

### Development
Developers can either:
1. **Use production instance** (recommended for simplicity) - just add same URL to development credentials
2. **Run locally** - `docker run -d -p 8888:8080 searxng/searxng` and set `SEARXNG_URL=http://localhost:8888/search`

## Edge Cases and Error Handling

1. **SearXNG unavailable**: Tool returns `{ error: "..." }`, AI handles gracefully
2. **Empty results**: Returns empty array, AI can try different query or inform user
3. **Timeout**: 15-second timeout, returns error if exceeded
4. **Invalid JSON response**: Returns error message
5. **Rate limiting**: Disabled on our SearXNG instance, not a concern

## Testing Strategy

1. **Unit tests** for `WebSearchTool` with mocked HTTP responses
2. **Model tests** for `Chat#available_tools` with both tools
3. **Controller tests** for `web_access` parameter handling
4. **Integration tests** verifying the full flow remains functional

Run full test suite: `rails test`

## Future Considerations

- Add search result caching if needed for performance
- Add category/engine filtering if users need specialized searches
- Consider adding search suggestions to the response
