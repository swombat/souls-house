<script>
  import { page, router } from '@inertiajs/svelte';
  import { PushPin, PushPinSlash, X, ArrowCounterClockwise } from 'phosphor-svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { Input } from '$lib/components/shadcn/input';
  import { Badge } from '$lib/components/shadcn/badge';
  import * as Card from '$lib/components/shadcn/card';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';

  let { account, path, terms = [], removed = [], keyterm_limit = 100 } = $props();

  let term = $state('');
  let submitting = $state(false);

  const SOURCE_LABELS = {
    manual: 'Added',
    built_in: 'Built in',
    correction: 'From a correction',
    harvested: 'Learned',
  };

  function addTerm(value = term) {
    const trimmed = value.trim();
    if (!trimmed || submitting) return;
    submitting = true;
    router.post(
      path,
      { term: trimmed },
      {
        preserveScroll: true,
        onSuccess: () => {
          if (value === term) term = '';
        },
        onFinish: () => {
          submitting = false;
        },
      }
    );
  }

  function setPinned(entry, pinned) {
    router.patch(path, { term: entry.term, pinned }, { preserveScroll: true });
  }

  function removeTerm(entry) {
    router.delete(path, { data: { term: entry.term }, preserveScroll: true });
  }
</script>

<AccountSettingsLayout
  {account}
  active="glossary"
  title="Glossary"
  description="Names and words that voice transcription should recognise in this account.">
  <FlashMessages flash={$page.props.flash} />

  <div class="space-y-8">
    <Card.Root>
      <Card.Header>
        <Card.Title>Add a word</Card.Title>
        <Card.Description>
          A name, product or bit of jargon people say out loud, like a resident's name or your company's. Up to five
          words.
        </Card.Description>
      </Card.Header>
      <Card.Content>
        <form
          class="flex gap-3"
          onsubmit={(event) => {
            event.preventDefault();
            addTerm();
          }}>
          <Input bind:value={term} maxlength={49} placeholder="e.g. a product or place name" aria-label="Word or phrase" />
          <Button type="submit" disabled={submitting || !term.trim()}>Add</Button>
        </form>
        {#if $page.props.errors?.term}
          <p class="mt-2 text-sm text-destructive">{$page.props.errors.term.join(', ')}</p>
        {/if}
      </Card.Content>
    </Card.Root>

    <section class="space-y-3">
      <div>
        <h2 class="text-xl font-semibold">In the glossary</h2>
        <p class="text-sm text-muted-foreground">Pinned words go first. Transcription uses the first {keyterm_limit}.</p>
      </div>

      {#if terms.length === 0}
        <Card.Root>
          <Card.Content class="py-8 text-center text-muted-foreground">No words yet.</Card.Content>
        </Card.Root>
      {:else}
        <Card.Root>
          <Card.Content class="divide-y p-0">
            {#each terms as entry, index (entry.term)}
              <div class="flex items-center justify-between gap-4 px-5 py-3" data-glossary-term={entry.term}>
                <div class="flex min-w-0 items-center gap-3">
                  <span class="truncate font-medium">{entry.term}</span>
                  <Badge variant="secondary">{SOURCE_LABELS[entry.source] ?? entry.source}</Badge>
                  {#if entry.pinned}
                    <Badge>Pinned</Badge>
                  {/if}
                  {#if index >= keyterm_limit}
                    <span class="text-xs text-muted-foreground">beyond the limit</span>
                  {/if}
                </div>
                <div class="flex shrink-0 items-center gap-1">
                  {#if entry.pinned}
                    <Button variant="ghost" size="icon" title="Unpin" onclick={() => setPinned(entry, false)}>
                      <PushPinSlash class="size-4" />
                    </Button>
                  {:else}
                    <Button variant="ghost" size="icon" title="Pin" onclick={() => setPinned(entry, true)}>
                      <PushPin class="size-4" />
                    </Button>
                  {/if}
                  <Button variant="ghost" size="icon" title="Remove" onclick={() => removeTerm(entry)}>
                    <X class="size-4" />
                  </Button>
                </div>
              </div>
            {/each}
          </Card.Content>
        </Card.Root>
      {/if}
    </section>

    {#if removed.length > 0}
      <section class="space-y-3">
        <div>
          <h2 class="text-xl font-semibold">Removed</h2>
          <p class="text-sm text-muted-foreground">These won't be added back automatically.</p>
        </div>
        <Card.Root>
          <Card.Content class="divide-y p-0">
            {#each removed as entry (entry.term)}
              <div class="flex items-center justify-between gap-4 px-5 py-3">
                <span class="truncate text-muted-foreground line-through">{entry.term}</span>
                <Button variant="ghost" size="sm" onclick={() => addTerm(entry.term)}>
                  <ArrowCounterClockwise class="mr-1 size-4" /> Restore
                </Button>
              </div>
            {/each}
          </Card.Content>
        </Card.Root>
      </section>
    {/if}
  </div>
</AccountSettingsLayout>
