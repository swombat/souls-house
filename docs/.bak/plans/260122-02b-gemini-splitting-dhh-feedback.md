# DHH-Style Code Review: Gemini Tool Result Stripping v2b

**Date**: 2026-01-23
**Reviewer**: Claude (channeling DHH)
**Spec Reviewed**: `260122-02b-gemini-splitting.md`

---

## Overall Assessment

This is **Rails-worthy**. The spec author has taken the feedback to heart and produced exactly what was requested: a simple brace-counting algorithm, no allowlist, no frontend button, no new routes, and a one-time rake task for cleanup. This is the kind of focused, pragmatic solution that belongs in a Rails codebase.

The implementation is now approximately 40 lines of code solving a real problem in the simplest possible way. Ship it.

---

## Minor Polish Suggestions

### 1. Consider Handling Leading Whitespace Consistently

The class method does `content.to_s.lstrip`, but the instance method checks `content&.lstrip&.start_with?("{")`. This is fine, but you could simplify the instance method:

```ruby
def has_concatenated_tool_result?
  return false unless role == "assistant" && content&.lstrip&.start_with?("{")

  cleaned = self.class.strip_tool_result_prefix(content)
  cleaned != content && cleaned.present?
end
```

Actually, looking closer, there is a subtle inconsistency. The class method does `.lstrip` before checking `start_with?`, then returns the lstripped version. The instance method compares `cleaned != content`, but `cleaned` will be lstripped while `content` may have leading whitespace.

This means a message with content `"  Hello"` (leading spaces, no JSON) would:
1. Pass into `strip_tool_result_prefix`
2. Get lstripped to `"Hello"`
3. Return `"Hello"` (unchanged after lstrip, since no `{`)
4. Compare `"Hello" != "  Hello"` = true
5. Incorrectly report `has_concatenated_tool_result? = true`

**Fix**: Compare against the lstripped original:

```ruby
def has_concatenated_tool_result?
  return false unless role == "assistant" && content&.lstrip&.start_with?("{")

  cleaned = self.class.strip_tool_result_prefix(content)
  cleaned != content.lstrip && cleaned.present?
end
```

Or simpler: just check if JSON was actually stripped:

```ruby
def has_concatenated_tool_result?
  return false unless role == "assistant" && content&.lstrip&.start_with?("{")

  original_lstripped = content.lstrip
  cleaned = self.class.strip_tool_result_prefix(content)
  cleaned.length < original_lstripped.length && cleaned.present?
end
```

This is a minor edge case (messages with leading whitespace before JSON), but worth handling correctly.

### 2. Add a Test for Leading Whitespace

Add a test case for content with leading whitespace:

```ruby
test "strip_tool_result_prefix handles leading whitespace" do
  content = '  {"success": true}Hello world'
  assert_equal "Hello world", Message.strip_tool_result_prefix(content)
end
```

### 3. The Rake Task Note is Good

The note to delete the rake task after running is the right approach. One-time tasks should not linger in the codebase.

---

## What Works Well

1. **Brace-counting algorithm**: Simple, handles nesting, fails gracefully. Approximately 15 lines. Perfect.

2. **No allowlist**: Stripping any leading JSON from assistant messages is the correct approach. No maintenance burden.

3. **Integration point**: `extract_message_content` is exactly where this belongs.

4. **Rake task for historical data**: Run it once, delete it. No ongoing UI complexity.

5. **Comprehensive tests**: The test cases cover the important scenarios including edge cases like blank content and JSON-only messages.

6. **Clear file changes summary**: The table at the bottom makes it obvious what files change and why.

---

## Final Verdict

The spec is ready for implementation. The one minor fix needed is the leading whitespace handling in `has_concatenated_tool_result?`. Everything else is clean, idiomatic Rails code.

This is the difference between a spec that tries to handle every theoretical edge case and one that solves the actual problem. Well done.

Ship it.
