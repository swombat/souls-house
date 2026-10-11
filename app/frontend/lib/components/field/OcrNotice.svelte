<script>
  // What Field OCR sends and where, said wherever it is on (FieldOcr).
  // kind: "page" (the list) or "file" (the upload form).
  let { kind = 'page' } = $props();
</script>

{#if kind === 'file'}
  If it's a PDF with scanned pages, an image of each such page (up to 50) is sent to Claude Haiku (Anthropic, through
  OpenRouter) to be transcribed; Anthropic doesn't train on it and may keep it for up to 30 days. Transcriptions are
  marked as a model's and may contain mistakes.
{:else}
  Scanned pages of PDFs brought in now are transcribed by Claude Haiku (Anthropic, through OpenRouter) from an image of
  each page, and marked as a model's; Anthropic doesn't train on them and may keep them for up to 30 days.
{/if}
