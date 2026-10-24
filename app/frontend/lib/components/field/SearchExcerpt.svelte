<script>
  // One search excerpt: plain text with the matched words marked, from the
  // [offset, length] pairs the server sends (never HTML). Offsets count
  // Unicode characters, so the text is split into code points, not UTF-16.
  let { excerpt } = $props();

  const pieces = $derived.by(() => {
    const chars = Array.from(excerpt?.text || '');
    const take = (from, to) => chars.slice(from, to).join('');
    const out = [];
    let cursor = 0;
    for (const [offset, length] of excerpt?.matches || []) {
      if (offset < cursor || offset + length > chars.length) continue;
      if (offset > cursor) out.push({ text: take(cursor, offset), hit: false });
      out.push({ text: take(offset, offset + length), hit: true });
      cursor = offset + length;
    }
    if (cursor < chars.length) out.push({ text: take(cursor), hit: false });
    return out;
  });
</script>

<p class="text-sm text-muted-foreground" data-testid="field-search-excerpt">
  …{#each pieces as piece, index (index)}{#if piece.hit}<mark class="bg-primary/20 text-foreground rounded-sm px-0.5"
        >{piece.text}</mark
      >{:else}{piece.text}{/if}{/each}…
</p>
