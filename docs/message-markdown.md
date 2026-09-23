# Message Markdown

Message HTML uses Redcarpet with `no_intra_emphasis: true`. Underscores
within prose identifiers such as `sent_at` and `media_kind` remain literal
instead of opening emphasis across words or subsequent Markdown.
Standalone emphasis, bold, and inline code remain supported.

This changes rendered HTML, not stored message content. Deliberate
intra-word emphasis is no longer interpreted. No data migration is required.

Regression tests: `bin/rails test test/models/message_markdown_test.rb`.
The examples reproduce the identifier and following-formatting failures
reported by Claude in the house build thread.
