<script>
  // "Show commitments" from the conversation menu (Daniel, jMaDAj): the
  // commitments residents made in this conversation, waiting ones first,
  // fetched each time the sheet opens. A bottom sheet, like View costs, so it
  // reads the same on a phone and a desk. Rescheduling and cancelling stay on
  // the resident's page; the sheet links there for whoever may manage.
  import * as Drawer from '$lib/components/shadcn/drawer/index.js';
  import { Button } from '$lib/components/shadcn/button';
  import { X } from 'phosphor-svelte';
  import { commitmentStatusLine, commitmentWhen } from '$lib/commitment-display';

  let { open = $bindable(false), accountId, chatId } = $props();

  let waiting = $state([]);
  let earlier = $state([]);
  let loading = $state(false);
  let failed = $state(false);
  let showEarlier = $state(false);
  let request = 0;

  async function load() {
    const mine = ++request;
    loading = true;
    failed = false;
    try {
      const response = await fetch(`/accounts/${accountId}/chats/${chatId}/commitments`, {
        headers: { Accept: 'application/json' },
        credentials: 'same-origin',
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const body = await response.json();
      if (mine !== request) return;
      waiting = body.waiting || [];
      earlier = body.earlier || [];
    } catch {
      if (mine === request) failed = true;
    } finally {
      if (mine === request) loading = false;
    }
  }

  $effect(() => {
    if (open && accountId && chatId) load();
  });

  $effect(() => {
    chatId;
    waiting = [];
    earlier = [];
    showEarlier = false;
  });
</script>

{#snippet card(c)}
  <li class="space-y-2 rounded-lg border p-3 sm:p-4" data-testid="conversation-commitment">
    <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
      <span class="text-sm font-medium">{c.resident_name}</span>
      <span class="text-xs text-muted-foreground">
        {c.status === 'scheduled' ? 'Due' : 'Was due'}
        {commitmentWhen(c.due_at, c.timezone)}
        <span class="whitespace-nowrap">{c.timezone}</span>
      </span>
    </div>
    <p class="text-sm font-medium" data-testid="conversation-commitment-headline">{c.headline}</p>
    {#if c.text && c.text.trim() !== c.headline}
      <details class="text-sm">
        <summary class="cursor-pointer text-xs text-muted-foreground">Full text</summary>
        <p class="mt-2 whitespace-pre-line break-words">{c.text}</p>
      </details>
    {/if}
    <p class="text-xs text-muted-foreground">
      {commitmentStatusLine(c, c.resident_name)}
      {#if c.destination === 'new_conversation'}
        {#if c.activation_url}
          Delivered in <a class="underline underline-offset-4" href={c.activation_url}>its own conversation</a>.
        {:else}
          Opens a new conversation in {c.room_name || 'Main'}.
        {/if}
      {/if}
    </p>
    {#if c.manage_url && c.status === 'scheduled'}
      <a class="inline-block text-xs underline underline-offset-4" href={c.manage_url}>Reschedule or cancel</a>
    {/if}
  </li>
{/snippet}

<Drawer.Root bind:open direction="bottom">
  <Drawer.Content class="max-h-[85vh]">
    <Drawer.Header class="sr-only">
      <Drawer.Title>Commitments</Drawer.Title>
      <Drawer.Description>Commitments residents made in this conversation.</Drawer.Description>
    </Drawer.Header>

    <div class="mx-auto flex max-h-[80vh] w-full max-w-2xl flex-col">
      <div class="flex items-start justify-between gap-4 border-b px-4 py-3 md:px-6">
        <div>
          <h3 class="text-lg font-semibold">Commitments</h3>
          <p class="text-sm text-muted-foreground">
            What residents have said they will come back to in this conversation, and when.
          </p>
        </div>
        <Button variant="ghost" size="icon" onclick={() => (open = false)} aria-label="Close commitments">
          <X size={18} />
        </Button>
      </div>

      <div class="space-y-4 overflow-y-auto px-4 py-4 md:px-6" data-testid="conversation-commitments">
        {#if failed}
          <p class="text-sm text-destructive">Couldn't load the commitments. Close and open again to retry.</p>
        {:else if loading && waiting.length === 0 && earlier.length === 0}
          <p class="text-sm text-muted-foreground">Loading…</p>
        {:else}
          {#if waiting.length === 0}
            <p
              class="rounded border bg-muted/30 p-4 text-sm text-muted-foreground"
              data-testid="no-waiting-commitments">
              Nothing is waiting in this conversation.
            </p>
          {:else}
            <ul class="space-y-3">
              {#each waiting as c (c.id)}
                {@render card(c)}
              {/each}
            </ul>
          {/if}

          {#if earlier.length > 0}
            <div class="space-y-3 border-t pt-3">
              <button
                type="button"
                class="text-sm font-medium text-muted-foreground underline-offset-4 hover:underline"
                aria-expanded={showEarlier}
                onclick={() => (showEarlier = !showEarlier)}>
                {showEarlier ? 'Hide' : 'Show'} delivered and cancelled ({earlier.length})
              </button>
              {#if showEarlier}
                <ul class="space-y-3 opacity-75">
                  {#each earlier as c (c.id)}
                    {@render card(c)}
                  {/each}
                </ul>
              {/if}
            </div>
          {/if}
        {/if}
      </div>
    </div>
  </Drawer.Content>
</Drawer.Root>
