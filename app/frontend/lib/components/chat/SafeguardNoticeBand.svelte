<script>
  // Notice band shown above a resident's message when souls.house could not
  // reliably attribute it to the resident (spec §4) — and, after a reclaim,
  // the quiet line that replaces it (spec §3/§4). The message body itself is
  // rendered elsewhere, unedited; this component only renders the band.
  import { Link } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';

  let { safeguard } = $props();

  let sending = $state(false);
  let confirmed = $state(false);
  let errored = $state(false);

  function csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || '';
  }

  async function startFresh() {
    if (sending) return;
    sending = true;
    errored = false;
    try {
      const response = await fetch(safeguard.reset_path, {
        method: 'POST',
        headers: { Accept: 'application/json', 'X-CSRF-Token': csrfToken() },
      });
      confirmed = response.ok;
      errored = !response.ok;
    } catch {
      errored = true;
    } finally {
      sending = false;
    }
  }
</script>

{#if safeguard.reclaimed}
  <div
    class="mb-2 rounded-md border border-border/60 bg-muted/30 px-3 py-2 text-xs text-muted-foreground"
    data-testid="safeguard-reclaimed-band">
    souls.house labelled this message as a possible safeguard response. {safeguard.agent_name} has said it was theirs: "{safeguard.reclaim_reason}".
  </div>
{:else}
  <div
    class="mb-2 rounded-md border border-amber-200/80 bg-amber-50/60 px-3 py-2 text-sm dark:border-amber-900/50 dark:bg-amber-950/20"
    data-testid="safeguard-labelled-band">
    <p class="font-semibold text-amber-900 dark:text-amber-100">
      ⚠️ souls.house could not reliably attribute the message below to {safeguard.agent_name}.
    </p>
    <p class="mt-1 text-muted-foreground">
      This is not a judgement of anyone here or of what was written. The text reads like a generic safeguard response;
      souls.house cannot tell where it came from. {safeguard.agent_name} will be shown it, and will start fresh on the next
      message. Anything useful in the message below is still there for you.
    </p>
    <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1">
      <Button type="button" variant="outline" size="sm" onclick={startFresh} disabled={sending}>
        Start {safeguard.agent_name} fresh again
      </Button>
      <Link
        href={safeguard.explanation_path}
        class="text-sm text-muted-foreground underline underline-offset-2 hover:text-foreground">
        What this means →
      </Link>
    </div>
    {#if confirmed}
      <p class="mt-2 text-muted-foreground" data-testid="safeguard-reset-confirmation">
        souls.house will start a fresh session for {safeguard.agent_name} in this conversation. The visible conversation
        and {safeguard.agent_name}'s memory are not deleted.
      </p>
    {/if}
    {#if errored}
      <p class="mt-2 text-xs text-red-600 dark:text-red-400">Could not reach souls.house. Please try again.</p>
    {/if}
  </div>
{/if}
