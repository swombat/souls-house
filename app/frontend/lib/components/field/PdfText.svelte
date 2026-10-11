<script>
  // A PDF's text, page by page (FieldFile::PdfExtraction): the page's own
  // text, and for scanned pages a model's transcription (FieldOcr), always
  // labelled as such. Text is shown as text (escaped), never as HTML. Pages
  // with nothing read say so; nothing is filled in for them.
  let { extraction, pages = null } = $props();

  function plural(n, word) {
    return `${n} ${word}${n === 1 ? '' : 's'}`;
  }

  let status = $derived.by(() => {
    const e = extraction;
    switch (e.status) {
      case 'pending':
        return 'Reading the text in this PDF…';
      case 'encrypted':
        return 'This PDF needs a password to open, so the house does not read it.';
      case 'failed':
        return `The house could not read this PDF${e.reason ? `: ${e.reason}` : ''}.`;
      default: {
        let line = `Text read from ${plural(e.pages_with_text, 'page')} of ${e.page_count}.`;
        if (e.pages_without_text > 0) {
          line += ` ${plural(e.pages_without_text, 'page')} ${e.pages_without_text === 1 ? 'has' : 'have'} no text of ${e.pages_without_text === 1 ? 'its' : 'their'} own (blank or scanned)`;
          line += e.transcription ? '.' : `, so nothing was read from ${e.pages_without_text === 1 ? 'it' : 'them'}.`;
        }
        if (e.transcription === 'pending') line += ' Transcribing the scanned pages…';
        if (e.pages_transcribed > 0) {
          line += ` ${plural(e.pages_transcribed, 'page')} transcribed by Claude Haiku from an image of the page; transcriptions may contain mistakes.`;
        }
        const untranscribed = (e.pages_transcription_failed ?? 0) + (e.pages_transcription_skipped ?? 0);
        if (untranscribed > 0) line += ` ${plural(untranscribed, 'page')} could not be transcribed.`;
        if (e.status === 'partial' && e.reason) line += ` Partly read: ${e.reason}.`;
        if (e.search_text_truncated) line += ' Search and summaries use only the beginning of the text.';
        return line;
      }
    }
  });

  function pageNote(page) {
    if (page.status === 'empty' && page.transcription) return 'No text of its own (blank or scanned).';
    if (page.status === 'empty') return 'No text of its own (blank or scanned). Nothing read.';
    if (page.status === 'skipped') return `Not read: ${page.reason || 'a limit was reached'}.`;
    return `Could not be read${page.reason ? `: ${page.reason}` : ''}.`;
  }
</script>

<div class="space-y-2" data-testid="field-file-pdf-text">
  <p class="text-xs uppercase tracking-wide text-muted-foreground">Text in this PDF</p>
  <p class="text-sm text-muted-foreground" data-testid="field-file-pdf-status">{status}</p>

  {#if pages?.length}
    <div class="max-h-[60vh] overflow-auto rounded border p-3 space-y-4">
      {#each pages as page (page.number)}
        <section data-testid="field-file-pdf-page">
          <p class="text-xs text-muted-foreground mb-1">Page {page.number}</p>
          {#if page.status === 'text'}
            <p class="whitespace-pre-wrap text-sm break-words">{page.text}</p>
            {#if page.reason}
              <p class="text-sm italic text-muted-foreground" data-testid="field-file-pdf-page-cut">{page.reason}.</p>
            {/if}
          {:else}
            <p class="text-sm italic text-muted-foreground">{pageNote(page)}</p>
          {/if}
          {#if page.transcription}
            {@const t = page.transcription}
            <div class="mt-2 border-l-2 border-amber-500/60 pl-3" data-testid="field-file-pdf-transcription">
              {#if t.status === 'text' || t.status === 'empty'}
                <p class="text-xs text-muted-foreground mb-1">
                  Transcribed by Claude Haiku from an image of the page. May contain mistakes.
                </p>
              {/if}
              {#if t.status === 'text'}
                <p class="whitespace-pre-wrap text-sm break-words">{t.text}</p>
                {#if t.reason}<p class="text-sm italic text-muted-foreground">{t.reason}.</p>{/if}
              {:else if t.status === 'empty'}
                <p class="text-sm italic text-muted-foreground">No readable text found on the page.</p>
              {:else}
                <p class="text-sm italic text-muted-foreground">Not transcribed{t.reason ? `: ${t.reason}` : ''}.</p>
              {/if}
            </div>
          {/if}
        </section>
      {/each}
    </div>
    {#if extraction.page_count > pages.length}
      <p class="text-xs text-muted-foreground">
        Showing the first {pages.length} of {extraction.page_count} pages. Download the file for the rest.
      </p>
    {/if}
  {/if}
</div>
