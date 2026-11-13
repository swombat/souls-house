<script>
  // A resident's commitments: one-shot promises it made to come back to
  // something at a time. Residents make and manage their own; a person who
  // may manage one can reschedule or cancel it here. There is no "create".
  import { router } from '@inertiajs/svelte';
  import { commitmentStatusLine, commitmentWhen } from '$lib/commitment-display';

  let { commitments = {}, agentName = 'This resident', canManageEssential = false } = $props();

  let items = $derived(commitments.items || []);
  let scheduled = $derived(items.filter((c) => c.status === 'scheduled'));
  let past = $derived(items.filter((c) => c.status !== 'scheduled'));
  let rescheduling = $state(null);
  let newTime = $state('');

  function localInputValue(value) {
    const date = new Date(value);
    const pad = (n) => String(n).padStart(2, '0');
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  function toUtcIso(local) {
    const date = new Date(local);
    return date.toISOString();
  }

  const when = commitmentWhen;
  const statusLine = (c) => commitmentStatusLine(c, agentName);

  function cancel(c) {
    if (!confirm(`Cancel this commitment of ${agentName}'s?`)) return;
    router.delete(c.manage_url, { preserveScroll: true });
  }

  function stop(c) {
    if (!confirm(`Stop the house waking ${agentName} for this commitment? The message stays in the conversation.`))
      return;
    router.delete(c.manage_url, { preserveScroll: true });
  }

  function startReschedule(c) {
    rescheduling = c.id;
    newTime = localInputValue(c.due_at);
  }

  function saveReschedule(c) {
    if (!newTime) return;
    router.patch(
      c.manage_url,
      { due_at: toUtcIso(newTime) },
      { preserveScroll: true, onSuccess: () => (rescheduling = null) }
    );
  }
</script>

{#snippet card(c)}
  <li class="rounded-lg border p-4 space-y-3" data-testid="commitment">
    <div class="flex items-baseline justify-between gap-3">
      <span class="font-medium"
        >Due {when(c.due_at, c.timezone)} <span class="text-xs text-muted-foreground">{c.timezone}</span></span>
      <span class="text-xs text-muted-foreground whitespace-nowrap">
        {c.destination === 'new_conversation' ? `New conversation in ${c.room_name || 'Main'}` : 'Same conversation'}
      </span>
    </div>
    {#if c.summary}<p class="text-sm font-medium" data-testid="commitment-summary">{c.summary}</p>{/if}
    <p class="whitespace-pre-line text-sm">{c.text}</p>
    <p class="text-xs text-muted-foreground">
      {statusLine(c)}
      {#if c.reschedule_count > 0}Rescheduled {c.reschedule_count === 1 ? 'once' : `${c.reschedule_count} times`}.{/if}
    </p>
    <p class="text-xs text-muted-foreground">
      Made in
      {#if c.source_url}<a class="underline underline-offset-4" href={c.source_url}>{c.source_conversation_title}</a
        >{:else}a conversation that is gone{/if}
      {#if c.activation_url && c.activation_conversation_id !== c.source_conversation_id}
        · delivered in <a class="underline underline-offset-4" href={c.activation_url}>its own conversation</a>
      {/if}
    </p>
    {#if canManageEssential && c.essential_url && c.status !== 'cancelled'}
      <label class="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={c.essential}
          onchange={(event) =>
            router.patch(c.essential_url, { essential: event.currentTarget.checked }, { preserveScroll: true })} />
        Essential: exempt from the allowance brake
      </label>
    {:else if c.essential}
      <p class="text-xs text-muted-foreground">Essential: exempt from the allowance brake</p>
    {/if}
    {#if c.manage_url}
      {#if rescheduling === c.id}
        <div class="flex flex-wrap items-center gap-2">
          <input
            type="datetime-local"
            class="input input-sm input-bordered"
            bind:value={newTime}
            aria-label="New time" />
          <button type="button" class="btn btn-sm" onclick={() => saveReschedule(c)}>Save</button>
          <button type="button" class="btn btn-sm btn-ghost" onclick={() => (rescheduling = null)}>Keep as is</button>
        </div>
      {:else if c.status === 'scheduled'}
        <div class="flex gap-2">
          <button type="button" class="btn btn-sm btn-ghost" onclick={() => startReschedule(c)}>Reschedule</button>
          <button type="button" class="btn btn-sm btn-ghost text-error" onclick={() => cancel(c)}>Cancel</button>
        </div>
      {:else}
        <div class="flex items-center gap-2">
          <button type="button" class="btn btn-sm btn-ghost text-error" onclick={() => stop(c)}>Stop waking</button>
          <span class="text-xs text-muted-foreground">A run that has already started can't be called back.</span>
        </div>
      {/if}
    {/if}
  </li>
{/snippet}

<div class="space-y-5">
  <div>
    <h2 class="text-xl font-semibold">Commitments</h2>
    <p class="text-sm text-muted-foreground">
      Things {agentName} has said it will come back to at a set time. When one is due, the house posts it in the conversation
      and wakes {agentName}, who decides what makes sense then. A delivered commitment is not a finished task. {agentName}
      makes and manages these; you can reschedule or cancel one here, or ask {agentName} in a conversation.
    </p>
  </div>

  {#if scheduled.length === 0}
    <p class="rounded border bg-muted/30 p-4 text-sm text-muted-foreground">{agentName} has nothing scheduled.</p>
  {:else}
    <ul class="space-y-3">
      {#each scheduled as c (c.id)}
        {@render card(c)}
      {/each}
    </ul>
  {/if}

  {#if past.length > 0}
    <div class="border-t pt-4 space-y-3">
      <h3 class="text-sm font-medium text-muted-foreground">Delivered and cancelled</h3>
      <ul class="space-y-3 opacity-75">
        {#each past as c (c.id)}
          {@render card(c)}
        {/each}
      </ul>
    </div>
  {/if}
</div>
