<script>
  import { Button } from '$lib/components/shadcn/button/index.js';

  let { onforget } = $props();
</script>

<details class="text-sm rounded-lg border border-destructive/30 p-3" data-testid="voices-danger-zone">
  <summary class="cursor-pointer font-medium text-destructive">Danger zone</summary>
  <div class="mt-2 space-y-2">
    <p class="text-muted-foreground">
      Forget every learned voice print and every sample in this Field, with the reviews given to them. Names on
      transcripts stay. Turning the switch above off is not this: it keeps everything.
    </p>
    <Button variant="destructive" size="sm" onclick={onforget} data-testid="voices-forget-all"
      >Forget all voices…</Button>
  </div>
</details>
