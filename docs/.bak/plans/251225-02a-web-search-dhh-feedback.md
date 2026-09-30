# DHH Review: Web Search Tool Implementation Spec

**Date**: 2025-12-25
**Reviewer**: DHH Standards Review
**Verdict**: MOSTLY RAILS-WORTHY, WITH CORRECTIONS NEEDED

## Overall Assessment

This is a solid, pragmatic implementation plan that demonstrates understanding of Rails conventions. The spec follows the existing `WebFetchTool` pattern appropriately, keeps the migration simple, and avoids unnecessary abstractions. However, there are several areas where the code deviates from Rails best practices or introduces unnecessary complexity that would not pass muster for Rails core.

The biggest issue: **the `num_results` parameter is premature optimization masquerading as user-friendliness**. The AI does not need this knob. Let it request results and trust the sensible default.

---

## Critical Issues

### 1. Remove the `num_results` Parameter - YAGNI Violation

```ruby
# BAD - Unnecessary parameter that adds complexity
param :num_results, type: :integer, desc: "Number of results to return (default: 10, max: 20)", required: false

def execute(query:, num_results: 10)
  num_results = [[num_results.to_i, 1].max, 20].min  # Defensive nonsense
```

This is exactly the kind of "flexibility" that Rails philosophy rejects. The AI does not need to specify how many results it wants. Pick a sensible default (10) and move on. The clamping logic (`[[num_results.to_i, 1].max, 20].min`) is a code smell - it exists because you added a parameter that did not need to exist.

```ruby
# GOOD - Simple, opinionated, done
RESULT_LIMIT = 10

def execute(query:)
  # ... fetch and return first RESULT_LIMIT results
end
```

### 2. The `require` Statements Inside `execute` Method

```ruby
def execute(query:, num_results: 10)
  require "net/http"
  require "json"
```

This is cargo-culted from `WebFetchTool` where it was also wrong. These are standard library components that should be required at the top of the file or, better yet, Rails autoloads them. Requiring inside a method is a micro-optimization from a bygone era.

```ruby
# GOOD - At the top of the file, or trust Rails
require "net/http"
require "json"

class WebSearchTool < RubyLLM::Tool
```

---

## Improvements Needed

### 3. The Three-Way Configuration Fallback is Excessive

```ruby
def searxng_url
  Rails.application.credentials.dig(:searxng, :url) ||
    ENV["SEARXNG_URL"] ||
    "https://searxng.granttree.co.uk/search"
end
```

Three fallback options is two too many. Rails credentials exist precisely to avoid this kind of defensive programming. If SearXNG is not configured, the feature should not work - that is a deployment error, not a runtime fallback scenario.

```ruby
# GOOD - One source of truth
def searxng_url
  Rails.application.credentials.dig(:searxng, :url) ||
    raise("SearXNG URL not configured in credentials")
end
```

If you truly need environment variable support for local development, use credentials for both environments. That is what `config/credentials/development.yml.enc` is for.

### 4. Inconsistent Error Handling Between Tools

`WebFetchTool` returns errors with context:
```ruby
{ error: "HTTP #{response.code}: #{response.message}", url: url }
```

`WebSearchTool` returns less useful errors:
```ruby
{ error: "Search failed: HTTP #{response.code}" }  # Missing message!
```

Follow the established pattern. Consistency matters.

```ruby
# GOOD - Matches WebFetchTool pattern
{ error: "HTTP #{response.code}: #{response.message}", query: query }
```

### 5. The Migration Has a Potential Index Issue

```ruby
rename_index :chats, :index_chats_on_can_fetch_urls, :index_chats_on_web_access
```

This assumes the index exists. But looking at the original migration, there might not be an index on this boolean column (and there probably should not be - boolean indexes are rarely useful). Verify this exists before attempting to rename it, or remove this line.

```ruby
# SAFER - Only rename the column
def change
  rename_column :chats, :can_fetch_urls, :web_access
end
```

### 6. The `json_attributes` Change Shows Unnecessary Code

The spec shows:
```ruby
json_attributes :title_or_default, :model_id, :model_name, :ai_model_name,
                :updated_at_formatted, :updated_at_short, :message_count, :web_access do |hash, options|
```

But the current code already has `can_fetch_urls` in the list. The spec should simply note "rename `can_fetch_urls` to `web_access` in the `json_attributes` declaration" rather than showing the full line. Minor point, but specs should be concise.

---

## What Works Well

### 7. The Tool Design Pattern is Correct

Following the existing `WebFetchTool` structure is the right call. Same timeout patterns, same error handling approach (mostly), same HTTP client usage. This is exactly how Rails conventions should propagate through a codebase.

### 8. The Migration is Appropriately Simple

A column rename is the right approach. No data migration needed, no complex transformation. This is Rails at its best - small, reversible changes.

### 9. The Test Strategy is Comprehensive

Using WebMock for HTTP stubbing, testing edge cases (timeout, empty results, error responses), and covering the model's `available_tools` behavior - this is production-quality testing.

### 10. The Single Checkbox Controlling Multiple Tools is Good UX

Rather than exposing "web fetch" and "web search" as separate checkboxes, unifying them under "web access" is the right abstraction. Users do not care about the implementation details.

---

## Refactored WebSearchTool

Here is the tool as it should be written:

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

**Changes from the spec:**
1. Removed `num_results` parameter entirely
2. Moved `require` statements to top of file
3. Extracted methods for clarity: `fetch_results`, `build_uri`, `parse_results`, `format_result`, `error_response`
4. Made constants explicit: `RESULT_LIMIT`, `OPEN_TIMEOUT`, `READ_TIMEOUT`
5. Removed ENV fallback - credentials only
6. Made error responses consistent with `WebFetchTool`

---

## Updated Test File

With `num_results` removed, simplify the tests:

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

  test "returns error for failed request" do
    stub_request(:get, /searxng/).to_return(status: 500, body: "", headers: {})

    result = @tool.execute(query: "test")

    assert_match(/500/, result[:error])
    assert_equal "test", result[:query]
  end

  test "returns error for timeout" do
    stub_request(:get, /searxng/).to_timeout

    result = @tool.execute(query: "test")

    assert result[:error].present?
  end

  test "handles empty results" do
    stub_searxng_empty

    result = @tool.execute(query: "obscure query")

    assert_equal [], result[:results]
    assert_equal 0, result[:total_results]
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
      query: "test",
      number_of_results: count * 100,
      results: count.times.map do |i|
        { url: "https://example#{i}.com", title: "Result #{i}", content: "Content #{i}" }
      end
    }
  end
end
```

**Changes:**
1. Removed tests for `num_results` clamping behavior (YAGNI - we removed the parameter)
2. Extracted stub helpers to reduce duplication
3. Simplified assertions

---

## Final Verdict

The implementation spec is **85% there**. The core architecture is sound, the patterns are correct, and the scope is appropriately limited. However, the `num_results` parameter is classic over-engineering, the configuration fallbacks are defensive programming that Rails credentials are meant to eliminate, and the error handling should be consistent with the existing tool.

Make the corrections noted above, and this would be Rails-worthy code.

**Rating**: Would accept with revisions.
