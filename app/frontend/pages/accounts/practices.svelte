<script>
  import { page, router } from '@inertiajs/svelte';
  import { createDynamicSync } from '$lib/use-sync';
  import { ArrowUp, ArrowDown, PencilSimple, X, Check } from 'phosphor-svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { Input } from '$lib/components/shadcn/input';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';

  let {
    account,
    path,
    practices = [],
    used = 0,
    limits = { max_length: 250, max_lines: 25, max_total: 3000 },
  } = $props();

  let draft = $state('');
  let editingId = $state(null);
  let editText = $state('');
  let busy = $state(false);
  let draftAccount;

  // Someone else's change (a person or a resident through the API) refreshes
  // the list; the hint carries no content.
  const updatePracticesSync = createDynamicSync();
  $effect(() => {
    const id = account?.id;
    updatePracticesSync(id ? { [`PracticeActivity:${id}`]: ['practices', 'used'] } : {});
  });

  // Switching account in the rail must not carry a half-typed line across.
  $effect(() => {
    if (draftAccount !== account?.id) {
      draftAccount = account?.id;
      draft = '';
      editingId = null;
      editText = '';
      busy = false;
    }
  });

  const errors = $derived(Object.values($page.props.errors ?? {}).flat());
  const full = $derived(practices.length >= limits.max_lines);
  const oneLine = (value) => value.replace(/\s+/g, ' ').trim();

  function send(method, url, data = {}, onDone = () => {}) {
    if (busy) return;
    busy = true;
    router[method](url, data, {
      preserveScroll: true,
      onSuccess: (response) => {
        if (Object.keys(response.props.errors ?? {}).length === 0) onDone();
      },
      onFinish: () => (busy = false),
    });
  }

  function add() {
    const text = oneLine(draft);
    if (!text) return;
    send('post', path, { text }, () => (draft = ''));
  }

  function startEdit(practice) {
    editingId = practice.id;
    editText = practice.text;
  }

  function saveEdit(practice) {
    const text = oneLine(editText);
    if (!text) return;
    send('patch', `${path}/${practice.id}`, { text }, () => (editingId = null));
  }

  function move(practice, delta) {
    send('patch', `${path}/${practice.id}`, { position: practice.position + delta });
  }

  function remove(practice) {
    if (!confirm(`Remove "${practice.text}"?`)) return;
    send('delete', `${path}/${practice.id}`);
  }

  function editor(practice) {
    if (!practice.updated_by) return 'someone no longer here';
    return practice.updated_by.kind === 'resident'
      ? `${practice.updated_by.name} (resident)`
      : practice.updated_by.name;
  }
</script>

<svelte:head><title>Practices · {account.name}</title></svelte:head>

<AccountSettingsLayout
  {account}
  active="practices"
  title="Practices"
  description="Standing lines about how this account works. Every resident reads them on each wake here.">
  <FlashMessages flash={$page.props.flash} />
  <section class="space-y-4" aria-labelledby="practices-heading">
    <div class="space-y-2">
      <h2 id="practices-heading" class="text-xl font-semibold">Practices</h2>
      <p class="text-sm text-muted-foreground">
        One line each, read in this order by residents at the start of every turn in this account. They are conventions,
        not permissions.
      </p>
      <p class="text-sm text-muted-foreground" data-testid="practices-guests-note">Guests see these practices too.</p>
    </div>

    {#if errors.length}
      <ul class="text-sm text-destructive" role="alert">
        {#each errors as error}<li>{error}</li>{/each}
      </ul>
    {/if}

    <ol class="space-y-2" aria-label="Practices in order">
      {#each practices as practice, index (practice.id)}
        <li class="flex items-start gap-2 rounded-xl border bg-background p-3" data-testid="practice-line">
          <span class="w-6 shrink-0 pt-1 text-sm text-muted-foreground">{practice.position}.</span>
          <div class="min-w-0 flex-1 space-y-1">
            {#if editingId === practice.id}
              <form
                class="flex gap-2"
                onsubmit={(event) => {
                  event.preventDefault();
                  saveEdit(practice);
                }}>
                <Input bind:value={editText} maxlength={limits.max_length} aria-label="Practice text" />
                <Button type="submit" size="sm" disabled={busy} aria-label="Save"><Check size={16} /></Button>
                <Button type="button" size="sm" variant="ghost" onclick={() => (editingId = null)} aria-label="Cancel"
                  ><X size={16} /></Button>
              </form>
              <p class="text-xs text-muted-foreground">{oneLine(editText).length} / {limits.max_length}</p>
            {:else}
              <p class="break-words text-sm">{practice.text}</p>
              <p class="text-xs text-muted-foreground" data-testid="practice-editor">
                Last changed by {editor(practice)}
              </p>
            {/if}
          </div>
          {#if editingId !== practice.id}
            <div class="flex shrink-0 items-center gap-1">
              <Button
                size="icon"
                variant="ghost"
                disabled={busy || index === 0}
                onclick={() => move(practice, -1)}
                aria-label={`Move "${practice.text}" up`}><ArrowUp size={16} /></Button>
              <Button
                size="icon"
                variant="ghost"
                disabled={busy || index === practices.length - 1}
                onclick={() => move(practice, 1)}
                aria-label={`Move "${practice.text}" down`}><ArrowDown size={16} /></Button>
              <Button
                size="icon"
                variant="ghost"
                disabled={busy}
                onclick={() => startEdit(practice)}
                aria-label={`Edit "${practice.text}"`}><PencilSimple size={16} /></Button>
              <Button
                size="icon"
                variant="ghost"
                disabled={busy}
                onclick={() => remove(practice)}
                aria-label={`Remove "${practice.text}"`}><X size={16} /></Button>
            </div>
          {/if}
        </li>
      {:else}
        <p class="text-sm text-muted-foreground">No practices yet, so residents' wakes here carry none.</p>
      {/each}
    </ol>

    <form
      class="space-y-1"
      onsubmit={(event) => {
        event.preventDefault();
        add();
      }}>
      <div class="flex gap-2">
        <Input
          bind:value={draft}
          maxlength={limits.max_length}
          disabled={full}
          placeholder={full ? `At most ${limits.max_lines} practices` : 'Finished threads get the done tag.'}
          aria-label="New practice" />
        <Button type="submit" disabled={busy || full || !oneLine(draft)}>Add</Button>
      </div>
      <p class="text-xs text-muted-foreground" data-testid="practices-usage">
        {used.toLocaleString('en-GB')} of {limits.max_total.toLocaleString('en-GB')} characters used ·
        {practices.length} of {limits.max_lines} lines · {limits.max_length} characters a line
      </p>
    </form>
  </section>
</AccountSettingsLayout>
