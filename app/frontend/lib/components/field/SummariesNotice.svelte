<script>
  // What Field summaries send and where, said wherever they are on (PR #275).
  // kind: "page" (the list), "file" or "recording" (the upload forms).
  let { kind = 'page' } = $props();
</script>

{#if kind === 'file'}
  If the house can read its text (plain-text formats), the text, title and note are sent to Claude Haiku (Anthropic,
  through OpenRouter) to write a short summary. Anthropic doesn't train on it and may keep it for up to 30 days.
{:else if kind === 'recording'}
  Once it's transcribed, the transcript, title and note are sent to Claude Haiku (Anthropic, through OpenRouter) to
  write a short summary; Anthropic doesn't train on it and may keep it for up to 30 days.
{:else}
  The short summaries under titles are written by Claude Haiku (Anthropic, through OpenRouter) from readable files and
  transcripts; Anthropic doesn't train on them and may keep them for up to 30 days.
{/if}
