# DHH Review: Web Search Tool Implementation Spec (Revision 2b)

**Date**: 2025-12-25
**Reviewer**: DHH Standards Review
**Verdict**: APPROVED WITH MINOR CORRECTIONS

## Overall Assessment

This revision successfully addresses all critical issues from the original feedback. The `num_results` parameter is gone, `require` statements are at the top, ENV fallbacks have been eliminated in favor of credentials-only configuration, error responses include query context consistently, and the migration is appropriately simple. The code is now properly factored into small, focused methods.

This is Rails-worthy code.

---

## Verification of Corrections

### 1. `num_results` Parameter Removed - VERIFIED

The spec now uses a simple constant:
```ruby
RESULT_LIMIT = 10

def execute(query:)
```

No defensive clamping logic, no unnecessary parameter. Correct.

### 2. `require` Statements at Top of File - VERIFIED

```ruby
require "net/http"
require "json"

class WebSearchTool < RubyLLM::Tool
```

Correct placement.

### 3. Credentials-Only Configuration - VERIFIED

```ruby
def searxng_url
  Rails.application.credentials.dig(:searxng, :url) ||
    raise("SearXNG URL not configured. Add searxng.url to Rails credentials.")
end
```

No ENV fallback. This is the Rails way.

### 4. Error Responses Consistent with WebFetchTool - VERIFIED

```ruby
def error_response(message, query)
  { error: message, query: query }
end
```

Matches the `WebFetchTool` pattern of returning `{ error: ..., url: url }`. Good.

### 5. Migration Simplified - VERIFIED

```ruby
def change
  rename_column :chats, :can_fetch_urls, :web_access
end
```

No index rename. Clean and safe.

### 6. Code Properly Factored - VERIFIED

The tool now has well-named private methods:
- `fetch_results` - HTTP request
- `build_uri` - URI construction
- `parse_results` - JSON parsing and transformation
- `format_result` - Single result formatting
- `error_response` - Error hash construction

Each method has a single responsibility. This is exemplary.

### 7. Tests Appropriately Simplified - VERIFIED

Tests no longer test `num_results` behavior. Stub helpers have been extracted. The test file is focused and DRY.

---

## Remaining Issues

### 1. WebFetchTool Still Has `require` Inside `execute`

The spec correctly moved `require` statements to the top for `WebSearchTool`, but the existing `WebFetchTool` (at `/app/tools/web_fetch_tool.rb`) still has:

```ruby
def execute(url:)
  require "net/http"
  require "uri"
```

For consistency, this should be corrected when implementing `WebSearchTool`. Add a note to the implementation plan to also fix `WebFetchTool` during this work.

### 2. Test for Missing Configuration Could Be More Idiomatic

```ruby
test "raises error when SearXNG URL not configured" do
  Rails.application.credentials.stubs(:dig).with(:searxng, :url).returns(nil)

  assert_raises(RuntimeError) { @tool.send(:searxng_url) }
end
```

Using `send` to test private methods is acceptable but not ideal. Consider testing through the public interface:

```ruby
test "raises error when SearXNG URL not configured" do
  Rails.application.credentials.stubs(:dig).with(:searxng, :url).returns(nil)

  error = assert_raises(RuntimeError) { @tool.execute(query: "test") }
  assert_match(/SearXNG URL not configured/, error.message)
end
```

This tests the actual behavior users will experience, not implementation details.

### 3. The `searxng_response` Helper Has a Quirky URL Hack

```ruby
def searxng_response(count)
  {
    # ...
    results: count.times.map do |i|
      { url: "https://example#{i}.com".gsub("example0", "rubyonrails"), ...}
    end
  }
end
```

The `.gsub("example0", "rubyonrails")` is confusing. It exists to make the first test pass (`assert_equal "https://rubyonrails.org"`), but it is not obvious why. Either:

1. Change the assertion to match the generated URL
2. Use a clearer helper structure

```ruby
# CLEANER
def searxng_response(count)
  {
    query: "ruby on rails",
    number_of_results: count * 100,
    results: Array.new(count) { |i| sample_result(i) }
  }
end

def sample_result(index)
  url = index.zero? ? "https://rubyonrails.org" : "https://example#{index}.com"
  { url: url, title: "Result #{index}", content: "Content #{index}" }
end
```

---

## Minor Suggestions

### 1. Consider Naming the Exception Class

Instead of:
```ruby
raise("SearXNG URL not configured. Add searxng.url to Rails credentials.")
```

Consider a specific error:
```ruby
raise ConfigurationError, "SearXNG URL not configured. Add searxng.url to Rails credentials."
```

This allows callers to rescue specifically if needed. However, this is a matter of taste - a RuntimeError is acceptable for a deployment configuration issue that should never occur in production.

### 2. The Timeout Constants Could Match WebFetchTool

`WebFetchTool` uses:
- `open_timeout: 5`
- `read_timeout: 10`

`WebSearchTool` uses:
- `OPEN_TIMEOUT = 10`
- `READ_TIMEOUT = 15`

The search tool has longer timeouts, which makes sense given SearXNG may be aggregating from multiple sources. This is fine - just noting the difference is intentional.

---

## What Works Well

1. **Single responsibility methods** - Each private method does one thing
2. **Constants for magic numbers** - Timeouts and limits are named and documented
3. **Consistent error handling** - Matches the established pattern
4. **Comprehensive tests** - Edge cases covered without over-testing
5. **Simple migration** - Just rename the column
6. **No unnecessary abstraction** - Does exactly what is needed, nothing more

---

## Final Verdict

**APPROVED**

The spec is ready for implementation. The code would be accepted into Rails core. The few remaining issues noted above are minor and can be addressed during implementation.

The revision demonstrates exactly the kind of response to feedback that makes a strong engineer: the corrections are thorough, the reasoning is understood (not just the mechanics), and the result is cleaner than what would have emerged from a less rigorous review process.

**Rating**: Rails-worthy.
