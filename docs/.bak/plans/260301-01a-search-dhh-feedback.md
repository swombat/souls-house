# DHH Review: Search Messages Across Chats

**Reviewer**: DHH-style code review
**Date**: 2026-03-01
**Verdict**: Mostly good. This spec has the right instincts -- no new gems, no new migrations, ILIKE over full-text search, a collection action instead of a separate controller. But there are several places where it drifts into unnecessary ceremony, duplicates existing patterns poorly, and introduces abstractions that earn no keep. Let me be specific.

---

## Overall Assessment

The architecture is sound. A collection route on `ChatsController`, a model scope on `Message`, a dedicated Svelte page -- this is exactly how you'd build a feature like this in Rails. The spec author clearly understands the codebase and has made sensible decisions about ILIKE vs. full-text search, reusing Pagy, and keeping the controller thin.

Where it falls short is in the details: the controller action is more verbose than it needs to be, the pagination helper is duplicated from `Admin::AuditLogsController` instead of extracted, the `snippet_around` method belongs nowhere near the `Message` model, and the navbar integration builds the URL by hand instead of using Inertia properly. These are the kinds of things that, left unchecked, accumulate into the kind of codebase that makes you sigh every time you open a file.

---

## Critical Issues

### 1. The pagination hash is duplicated, not extracted

The spec copies the exact same pagination hash from `Admin::AuditLogsController` into a new `search_pagination` private method. This is a DRY violation. The identical Pagy-to-hash transformation now lives in two places. When you change one, you will forget to change the other.

**Fix**: Extract a shared `pagy_to_hash` method into `ApplicationController` or a concern. Both controllers should call it.

```ruby
# app/controllers/concerns/pagy_serializable.rb (or just in ApplicationController)
def pagy_to_hash(pagy)
  return {} unless pagy

  {
    count: pagy.count,
    page: pagy.page,
    pages: pagy.pages,
    last: pagy.last,
    from: pagy.from,
    to: pagy.to,
    prev: pagy.prev,
    next: pagy.next,
    series: pagy.series.collect(&:to_s),
    per_page: pagy.vars[:limit].to_s
  }
end
```

Then both controllers simply call `pagy_to_hash(@pagy)`. One line, not fifteen.

### 2. `snippet_around` does not belong on `Message`

The `snippet_around` method is a presentation concern. It takes a search query -- something the Message model should know nothing about -- and produces a display-oriented snippet. This is the kind of thing that bloats models into god objects.

The Message model already has 600+ lines. It does not need to grow further with search-presentation logic.

**Fix**: This is a simple utility. Put it in the controller as a private method, or better yet, inline it into `search_result_json` since that is the only place it is called. If you insist on extracting it, a plain Ruby module (`Message::SearchSnippet` or similar) would work, but honestly a private controller method is fine for something this small.

```ruby
# In ChatsController, private
def snippet_around(content, query)
  return content.truncate(200) if content.blank? || query.blank?

  lines = content.lines
  match_index = lines.index { |line| line.downcase.include?(query.downcase) }
  return content.truncate(200) unless match_index

  start = [match_index - 1, 0].max
  finish = [match_index + 1, lines.length - 1].min
  lines[start..finish].map(&:strip).join("\n").truncate(300)
end
```

### 3. The navbar search builds the URL by hand

This is sloppy:

```javascript
router.visit(searchAccountChatsPath(currentAccount.id) + '?q=' + encodeURIComponent(navSearchQuery.trim()));
```

You are manually concatenating query parameters onto a URL. This is what `router.get` with params is for, which the spec itself uses correctly on the search results page. Be consistent.

**Fix**:

```javascript
function handleNavSearch(event) {
  event.preventDefault();
  if (!navSearchQuery.trim() || !currentAccount?.id) return;
  router.get(searchAccountChatsPath(currentAccount.id), { q: navSearchQuery.trim() });
  navSearchQuery = '';
}
```

---

## Improvements Needed

### 4. The controller action has unnecessary ceremony

The `search` action initializes `results = []` and then conditionally populates it. This is defensive programming that adds visual noise. Let the empty case flow naturally.

**Current** (from spec):
```ruby
def search
  query = params[:q].to_s.strip
  results = []

  if query.present?
    scope = Message.search_in_account(current_account, query)
    @pagy, messages = pagy(scope, limit: 20)
    results = messages.map { |message| search_result_json(message, query) }
  end

  render inertia: "chats/search", props: {
    query: query,
    results: results,
    pagination: search_pagination,
    account: current_account.as_json
  }
end
```

**Better**:
```ruby
def search
  @query = params[:q].to_s.strip

  if @query.present?
    @pagy, @messages = pagy(Message.search_in_account(current_account, @query), limit: 20)
  end

  render inertia: "chats/search", props: {
    query: @query,
    results: (@messages || []).map { |m| search_result_json(m, @query) },
    pagination: pagy_to_hash(@pagy),
    account: current_account.as_json
  }
end
```

Fewer local variables, fewer lines, same behavior. The `(@messages || []).map` is idiomatic Ruby -- it handles the nil case without a conditional branch.

### 5. `search_result_json` should use a simpler date format

```ruby
created_at: message.created_at.strftime("%b %d, %Y at %l:%M %p")
```

This produces timestamps like "Mar 01, 2026 at  3:45 PM" (note the leading space from `%l`). The existing codebase uses `%l:%M %p` in `created_at_formatted` on Message. Consider reusing that or using `I18n.l` for consistency, but at minimum use `%-l` to strip the leading space.

### 6. The `handleKeydown` function on the search page is unnecessary

The search input is inside a `<form>` element. Pressing Enter in a form input already triggers `onsubmit`. The explicit `onkeydown` handler that checks for Enter is redundant.

**Remove**:
```javascript
function handleKeydown(event) {
  if (event.key === 'Enter') {
    handleSearch(event);
  }
}
```

And remove `onkeydown={handleKeydown}` from the input. The `<form onsubmit={handleSearch}>` already handles this.

### 7. The `currentPage` state is unused

```javascript
let currentPage = $state(pagination.page || 1);
```

This `currentPage` is bound to `PaginationNav` but never read anywhere in the search page component itself. The `PaginationNav` component manages its own display via the `pagination` prop. The `bind:currentPage` is a write-back that goes nowhere. Remove the state variable and the bind -- just pass `pagination` and `onPageChange`.

### 8. The `goToChat` function is unnecessary indirection

```javascript
function goToChat(chatId) {
  router.visit(accountChatPath(account.id, chatId));
}
```

This wraps a single line in a function, then is called as `onclick={() => goToChat(result.chat_id)}`. Either inline it or use a more direct pattern. For a list of clickable items, this is fine as-is for readability, but the function name should be more specific since you are navigating, not "going" anywhere. Actually, this one is borderline -- I would leave it but note it is a matter of taste.

### 9. The `account` prop is unnecessary

The spec passes `account: current_account.as_json` to the search page. But looking at the navbar component, `$page.props.account` is already available via Inertia's shared data (it is used as `currentAccount` in the navbar). If `account` is already in shared props (which it appears to be based on how the navbar accesses it), passing it again as a page-specific prop is redundant.

Verify whether `current_account.as_json` is already included in shared Inertia props. If it is, use `$page.props.account` in the Svelte component instead of receiving it as a dedicated prop.

### 10. XSS via `{@html}` deserves more careful treatment

The spec acknowledges the `{@html highlightMatch(result.snippet, query)}` pattern and says "XSS risk is minimal." Minimal is not zero. The snippet comes from user-generated message content. If a message contains `<script>alert('xss')</script>`, the `highlightMatch` function will pass it through to `{@html}` with only the search term wrapped in `<mark>` tags.

**Fix**: Escape HTML entities in the snippet *before* inserting the `<mark>` tags.

```javascript
function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

function highlightMatch(text, term) {
  if (!term || !text) return escapeHtml(text);
  const escaped = escapeHtml(text);
  const termEscaped = term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const regex = new RegExp(`(${termEscaped})`, 'gi');
  return escaped.replace(regex, '<mark class="bg-yellow-200 dark:bg-yellow-800 rounded px-0.5">$1</mark>');
}
```

This is not optional. User content rendered via `{@html}` without escaping is a security defect.

---

## What Works Well

1. **The routing decision is correct.** A collection route on `ChatsController` is exactly right. No need for a `SearchController`. The URL reads naturally: `/accounts/:id/chats/search`.

2. **ILIKE over full-text search is the right call.** Simple, no migrations, works for the use case. The spec correctly identifies that full-text search can be layered in later if needed. This is pragmatic engineering.

3. **The scope design is clean.** `Message.search_in_account(account, query)` is well-named, handles the blank case with `return none`, uses `sanitize_sql_like`, and filters to only user/assistant roles. This is proper Rails.

4. **Reusing `PaginationNav` and Pagy** keeps the codebase consistent. Good.

5. **The test coverage is appropriate.** Tests for happy path, case insensitivity, empty query, discarded chats, and authentication. Not over-tested, not under-tested.

6. **The mobile fallback** (search link in hamburger menu) is a thoughtful touch.

7. **The Svelte component structure** is straightforward -- props in, render out, navigate on click. No over-engineered state management.

---

## Summary of Required Changes

| Priority | Issue | Action |
|----------|-------|--------|
| **Must fix** | XSS via `{@html}` | Escape HTML in snippets before inserting `<mark>` tags |
| **Must fix** | Duplicated pagination hash | Extract `pagy_to_hash` into `ApplicationController` |
| **Must fix** | `snippet_around` on Message model | Move to controller private method |
| **Must fix** | Manual URL building in navbar | Use `router.get` with params object |
| **Should fix** | Verbose controller action | Simplify to fewer local variables |
| **Should fix** | Redundant `handleKeydown` | Remove (form already handles Enter) |
| **Should fix** | Leading space in time format | Use `%-l` instead of `%l` |
| **Should fix** | Unused `currentPage` state | Remove dead state variable |
| **Nice to have** | Redundant `account` prop | Use shared Inertia props if available |

The bones are good. Clean these up and it is a solid, Rails-worthy feature.
