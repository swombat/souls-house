<script>
  import { router, Link } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { ArrowLeft, Pause, Play, PencilSimple, Trash, ChatCircle } from 'phosphor-svelte';
  import RhythmStateBadge from '$lib/components/rhythms/RhythmStateBadge.svelte';
  import RhythmResidentChips from '$lib/components/rhythms/RhythmResidentChips.svelte';
  import { editRhythmPath, formatWhen, rhythmActionPath, rhythmPath, rhythmsPath } from '$lib/rhythms';

  let { account, rhythm } = $props();

  let pausing = $state(false);
  let pauseReason = $state('');
  let busy = $state(false);

  const holds = $derived(rhythm.holds ?? []);
  const occurrences = $derived(rhythm.occurrences ?? []);
  const zone = $derived(rhythm.timezone_identifier ?? rhythm.timezone);
  const nextRun = $derived(formatWhen(rhythm.next_run_at, zone));
  const residentHolds = $derived(holds.filter((hold) => hold.holder_type === 'agent'));

  function post(action, data = {}) {
    busy = true;
    router.post(rhythmActionPath(account.id, rhythm.id, action), data, {
      preserveScroll: true,
      onFinish: () => (busy = false),
      onSuccess: () => {
        pausing = false;
        pauseReason = '';
      },
    });
  }

  function destroy() {
    if (!confirm(`Delete "${rhythm.title}"? Conversations it has already started will stay.`)) return;
    router.delete(rhythmPath(account.id, rhythm.id));
  }
</script>

<svelte:head>
  <title>{rhythm.title}</title>
</svelte:head>

<div class="mx-auto max-w-3xl p-8">
  <Link
    href={rhythmsPath(account.id)}
    class="mb-6 inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground">
    <ArrowLeft size={14} />
    Rhythms
  </Link>

  <div class="flex items-start justify-between gap-4">
    <div class="min-w-0">
      <div class="flex items-center gap-3">
        <h1 class="truncate text-3xl font-bold">{rhythm.title}</h1>
        <RhythmStateBadge state={rhythm.state} holdCount={holds.length} />
      </div>
      <p class="mt-1 text-muted-foreground">
        {rhythm.schedule_description} · set up by {rhythm.creator?.name}
      </p>
    </div>
    {#if rhythm.can_manage}
      <div class="flex shrink-0 gap-2">
        <Button variant="outline" size="sm" href={editRhythmPath(account.id, rhythm.id)}>
          <PencilSimple class="mr-1 size-4" />Edit
        </Button>
        <Button variant="outline" size="sm" onclick={destroy} aria-label="Delete rhythm">
          <Trash class="size-4" />
        </Button>
      </div>
    {/if}
  </div>

  <div class="mt-6 grid gap-6 sm:grid-cols-[1fr_auto]">
    <div class="space-y-1 text-sm">
      <div class="text-muted-foreground">With</div>
      <RhythmResidentChips residents={rhythm.residents} />
    </div>
    <div class="space-y-1 text-sm sm:text-right">
      <div class="text-muted-foreground">Next</div>
      <div class="font-medium">{rhythm.state === 'paused' ? 'Not while paused' : (nextRun ?? '—')}</div>
    </div>
  </div>

  <section class="mt-8">
    <h2 class="mb-2 text-sm font-medium text-muted-foreground">Opening message</h2>
    <div class="whitespace-pre-wrap rounded-lg border border-border bg-muted/20 p-4 text-sm">{rhythm.opening}</div>
  </section>

  {#if holds.length > 0}
    <section class="mt-8">
      <h2 class="mb-2 text-sm font-medium text-muted-foreground">Paused by</h2>
      <ul class="divide-y divide-border rounded-lg border border-border">
        {#each holds as hold (hold.id)}
          <li class="flex items-start justify-between gap-4 p-4 text-sm">
            <div>
              <div class="font-medium">
                {hold.holder_name}
                {#if hold.holder_type === 'agent'}<span class="font-normal text-muted-foreground">
                    (resident)</span
                  >{/if}
                {#if hold.holder_type === 'system'}<span class="font-normal text-muted-foreground">
                    (automatic)</span
                  >{/if}
              </div>
              {#if hold.reason}<p class="mt-0.5 text-muted-foreground">{hold.reason}</p>{/if}
              <p class="mt-0.5 text-xs text-muted-foreground">{formatWhen(hold.created_at, zone)}</p>
            </div>
          </li>
        {/each}
      </ul>
      {#if residentHolds.length > 0}
        <p class="mt-2 text-xs text-muted-foreground">
          A resident's pause can only be lifted by that resident. You can ask them about it in a conversation.
        </p>
      {/if}
    </section>
  {/if}

  {#if rhythm.can_manage || rhythm.can_resume}
    <section class="mt-8 flex flex-wrap items-start gap-3">
      {#if rhythm.can_resume}
        <Button variant="outline" disabled={busy} onclick={() => post('resume')}>
          <Play class="mr-1 size-4" />Resume
        </Button>
      {/if}
      {#if rhythm.can_manage && rhythm.state !== 'paused' && !pausing}
        <Button variant="outline" disabled={busy} onclick={() => (pausing = true)}>
          <Pause class="mr-1 size-4" />Pause
        </Button>
      {/if}
      {#if pausing}
        <form
          class="flex w-full flex-wrap items-center gap-2 sm:w-auto"
          onsubmit={(event) => {
            event.preventDefault();
            post('pause', { reason: pauseReason });
          }}>
          <Input bind:value={pauseReason} placeholder="Reason (optional)" class="w-64" />
          <Button type="submit" disabled={busy}>Pause</Button>
          <Button type="button" variant="ghost" onclick={() => (pausing = false)}>Cancel</Button>
        </form>
      {/if}
      {#if rhythm.can_manage}
        <Button
          variant="outline"
          disabled={busy || rhythm.state === 'paused'}
          title={rhythm.state === 'paused'
            ? 'Resume it first'
            : 'Opens one conversation now; the schedule stays the same'}
          onclick={() => post('start', { request_key: rhythm.start_request_key })}>
          <ChatCircle class="mr-1 size-4" />Start one now
        </Button>
      {/if}
    </section>
  {/if}

  <section class="mt-10">
    <h2 class="mb-2 text-sm font-medium text-muted-foreground">Conversations it has started</h2>
    {#if occurrences.length === 0}
      <p class="text-sm text-muted-foreground">None yet.</p>
    {:else}
      <ul class="divide-y divide-border rounded-lg border border-border">
        {#each occurrences as occurrence (occurrence.id)}
          <li class="flex items-center justify-between gap-4 p-4 text-sm">
            <div class="min-w-0">
              {#if occurrence.chat_url}
                <Link href={occurrence.chat_url} class="truncate font-medium hover:underline">{occurrence.title}</Link>
              {:else}
                <span class="truncate font-medium">{occurrence.title}</span>
              {/if}
              <div class="mt-0.5 flex flex-wrap gap-2 text-xs text-muted-foreground">
                <span>{formatWhen(occurrence.scheduled_for, zone)}</span>
                {#if occurrence.manual}<span class="rounded bg-muted px-1.5">started by hand</span>{/if}
                {#if occurrence.late}<span
                    class="rounded bg-amber-100 px-1.5 text-amber-800 dark:bg-amber-950 dark:text-amber-300">late</span
                  >{/if}
              </div>
            </div>
            <span class="max-w-[50%] shrink-0 text-right text-xs text-muted-foreground">{occurrence.status}</span>
          </li>
        {/each}
      </ul>
    {/if}
  </section>
</div>
