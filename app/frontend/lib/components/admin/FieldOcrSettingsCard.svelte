<script>
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Switch } from '$lib/components/shadcn/switch';

  let { form, status = {} } = $props();
</script>

<Card>
  <CardHeader>
    <CardTitle>Reading scanned PDFs</CardTitle>
    <CardDescription>
      When this is on, a page of a PDF brought into the Field that has no text of its own (a scan), or very little, is
      turned into an image inside the house and sent to Claude Haiku 5.5 (Anthropic, through OpenRouter, on the house's
      key) to be transcribed. Anthropic doesn't train on it and may keep it for up to 30 days. Transcriptions are shown
      as a model's and may contain mistakes. A transcribed page's text, with the file's title and note, is then
      summarised like any readable file, also by Claude Haiku; files already transcribed stay summarised that way if
      this is turned off. Only PDFs brought in after it is turned on are sent; the Field's existing files are not. Up to
      50 pages of a file and 500 pages per account a day.
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-4">
    <label class="flex items-center gap-3">
      <Switch
        aria-label="Transcribe scanned PDF pages"
        checked={!!form.field_ocr_enabled}
        onCheckedChange={(on) => (form.field_ocr_enabled = on)} />
      <span class="font-medium">Transcribe scanned PDF pages</span>
    </label>

    <div class="space-y-2">
      <label for="field_ocr_daily_usd_ceiling" class="font-medium">Most the house spends on it per day (USD)</label>
      <input
        id="field_ocr_daily_usd_ceiling"
        class="block h-10 w-28 rounded-md border bg-background px-3"
        type="number"
        min="0"
        max="100"
        step="0.01"
        required
        bind:value={form.field_ocr_daily_usd_ceiling} />
      <p class="text-sm text-muted-foreground" data-testid="field-ocr-status">
        Each page is charged against this before it is sent: $0.003 is held until the real cost is known (measured on 11
        October 2026: $0.0003 for a nearly empty page, $0.0005 for a full page of text). Failed calls still count. At
        the limit, the rest of the day's pages are left untranscribed and say so. {#if status.enabled_at}On since {new Date(
            status.enabled_at
          ).toLocaleString()}.{/if}
        Spent today: ${Number(status.spent_today ?? 0).toFixed(4)}.
      </p>
    </div>
  </CardContent>
</Card>
