# DHH Review: Search Messages v2

**Reviewer**: DHH-style code review
**Date**: 2026-03-01
**Spec reviewed**: `/docs/plans/260301-01b-search.md`
**Previous feedback**: `/docs/plans/260301-01a-search-dhh-feedback.md`

---

## Overall Assessment

This is a significant improvement. Every critical issue from v1 has been addressed, and addressed correctly. The XSS fix is solid, the pagination helper is properly extracted, `snippet_around` lives in the controller where it belongs, the navbar uses `router.get` with params, the redundant `handleKeydown` and `currentPage` state are gone, and the `account` prop was removed in favor of shared Inertia data. The spec author clearly read the feedback carefully and made the right calls.

What remains is minor. This spec is ready for implementation with a small handful of refinements.

---

## V1 Feedback: Status

| Issue | Status | Notes |
|-------|--------|-------|
| XSS via `{@html}` | Fixed | `escapeHtml` before `<mark>` insertion -- correct approach |
| Duplicated pagination hash | Fixed | Extracted to `ApplicationController#pagy_to_hash` |
| `snippet_around` on Message | Fixed | Moved to controller private method |
| Manual URL building in navbar | Fixed | Uses `router.get` with params |
| Verbose controller action | Fixed | `(@messages \|\| []).map` pattern, instance variables |
| Redundant `handleKeydown` | Fixed | Removed |
| Leading space in time format | Fixed | `%-l` and `%-d` |
| Unused `currentPage` state | Fixed | Removed |
| Redundant `account` prop | Fixed | Uses `$page.props.account` via shared Inertia data |

All nine issues resolved. Well done.

---

## Remaining Issues

### 1. The `highlightMatch` function has a subtle escaping mismatch

The function escapes the snippet HTML first, then runs a regex with the raw search term against the escaped text. This is the right order of operations for XSS safety, but it means the regex will fail to match if the search term itself contains characters that get HTML-escaped.

Example: if a user searches for `a&b` or `a<b`, the snippet text gets escaped (so `&` becomes `&amp;`), but the regex still looks for the literal string `a&b`. No match, no highlight.

This is an edge case that will rarely matter in practice -- people rarely search for strings containing `<`, `>`, or `&` -- but it is worth noting. The safe fix, if you want it, is to also escape the search term before building the regex:

```javascript
function highlightMatch(text, term) {
  if (!term || !text) return escapeHtml(text || '');
  const escaped = escapeHtml(text);
  const termEscaped = escapeHtml(term).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const regex = new RegExp(`(${termEscaped})`, 'gi');
  return escaped.replace(regex, '<mark class="bg-yellow-200 dark:bg-yellow-800 rounded px-0.5">$1</mark>');
}
```

Note the `escapeHtml(term)` before the regex-escape step. This ensures the regex matches against the same escaped representation. Not critical, but it is the correct thing to do.

### 2. The `snippet_around` fallback is subtly wrong

```ruby
def snippet_around(content, query)
  return content.truncate(200) if content.blank? || query.blank?
```

If `content` is blank, `.truncate(200)` on a blank string returns a blank string. That is fine. But the method signature says it takes `content` and `query` as arguments, and the caller already has `@query.present?` as a guard. The `query.blank?` branch in `snippet_around` is unreachable dead code -- the method is only called inside `search_result_json`, which is only called when `@query.present?`. Not a bug, just unnecessary defensiveness. Leave it or remove it -- either way is fine.

### 3. The `PaginationNav` component accepts `class` but the spec passes it as an attribute

```svelte
<PaginationNav
  {pagination}
  onPageChange={handlePageChange}
  class="mt-6" />
```

Looking at the actual `PaginationNav` component, it accepts `class: className = ''` via props and applies it to the wrapper div as `{className}`. This will work. No issue here -- just confirming I checked.

### 4. The audit logs refactoring note about `items` vs `per_page` is correct but should be verified

The spec notes:

> The old inline hash had both `items` and `per_page` keys with identical values. The shared helper only includes `per_page`, which is the one actually used by `PaginationNav`. Removing the redundant `items` key is a cleanup.

I confirmed this against the `PaginationNav` component -- it uses `pagination.per_page` on line 36. The `items` key is indeed unused. Good cleanup.

### 5. Consider truncating the search query param

The spec mentions this as optional:

> Very long search terms: Truncated naturally by ILIKE performance (no explicit limit needed, but could add `params[:q].to_s.first(200)` if desired).

I would do it. Not for ILIKE performance, but because there is no reason to accept a 10,000-character search query. A `first(500)` is one method call and prevents abuse. Add it to the controller:

```ruby
@query = params[:q].to_s.strip.first(500)
```

---

## What Works Well

Everything that worked well in v1 still works well, and the fixes are clean. Specifically:

1. The `pagy_to_hash` extraction is exactly right -- a private method on `ApplicationController`, not a concern, not a module. Appropriate for something this small that two controllers need.

2. The controller action reads cleanly now. Instance variables, `(@messages || []).map`, no ceremony.

3. The XSS fix is the textbook approach: escape first, then insert trusted markup. Solid.

4. Using `$page.props.account` instead of a redundant prop demonstrates understanding of how Inertia's shared data works.

5. The test coverage is appropriate. The note about not testing `snippet_around` in isolation is correct -- it is a private method exercised through integration.

---

## Summary

| Priority | Issue | Action |
|----------|-------|--------|
| Nice to have | `highlightMatch` escaping mismatch on special chars | Escape the search term too before regex |
| Nice to have | Truncate search query to prevent abuse | Add `.first(500)` |

This spec is ready for implementation. The architecture is sound, the feedback was properly incorporated, and the remaining issues are minor polish. Ship it.
