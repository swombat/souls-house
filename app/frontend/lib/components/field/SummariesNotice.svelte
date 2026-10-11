<script>
  // What Field summaries send and where, said wherever they are on (PR #275).
  // kind: "page" (the list), "file" or "recording" (the upload forms).
  // ocr: whether scanned PDF pages are being transcribed (FieldOcr); their
  // transcriptions are summarised like any readable text.
  let { kind = 'page', ocr = false } = $props();
</script>

{#if kind === 'file'}
  {#if ocr}
    If the house can read its text (plain-text formats, and PDFs, including scanned pages once a model has transcribed
    them), the text, title and note are sent to Claude Haiku (Anthropic, through OpenRouter) to write a short summary.
  {:else}
    If the house can read its text (plain-text formats, and PDFs that carry their own text, not scans), the text, title
    and note are sent to Claude Haiku (Anthropic, through OpenRouter) to write a short summary.
  {/if}
  Anthropic doesn't train on it and may keep it for up to 30 days.
{:else if kind === 'recording'}
  Once it's transcribed, the transcript, title and note are sent to Claude Haiku (Anthropic, through OpenRouter) to
  write a short summary; Anthropic doesn't train on it and may keep it for up to 30 days.
{:else}
  The short summaries under titles are written by Claude Haiku (Anthropic, through OpenRouter) from readable files
  (including scanned PDF pages a model has transcribed) and recording transcripts; Anthropic doesn't train on them and
  may keep them for up to 30 days.
{/if}
