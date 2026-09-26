# Temporary dependency fixes

## svelte-streamdown 2.6.1 — honour `parseIncompleteMarkdown={false}`

`Block.svelte` unconditionally repairs incomplete Markdown, ignoring the public
prop. An unmatched dollar in a completed shell path consequently becomes an
invented math expression swallowing the rest of the paragraph. The patch honours
an explicit false while preserving the dependency's default streaming behavior.
`MessageBubble` opts into repair only while a message is streaming.

Owner: Mira. Remove this patch when upgrading to a release which honours this
prop, keeping the MessageBubble and mobile-layout regression tests. Docker must
copy `patches/` before the frozen Bun install. The patch key uses the tarball URL
because this repository's existing lockfile records dependencies that way.
