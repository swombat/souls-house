<script>
  // "Merge with other speaker": one person written down under two names
  // (Ants / Ant Hiron). Pick the other speaker by search, then which of the
  // two names to keep. The server moves everything to the picked speaker.
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { MagnifyingGlass } from 'phosphor-svelte';

  let { voice, voices = [], base, onMerged = () => {}, onCancel = () => {} } = $props();

  let search = $state('');
  let target = $state(null);
  let name = $state('');
  let error = $state('');
  let merging = $state(false);

  const candidates = $derived.by(() => {
    const query = search.trim().toLocaleLowerCase();
    return voices
      .filter((other) => other.id !== voice.id && other.name.toLocaleLowerCase().includes(query))
      .slice(0, 8);
  });

  const usedLine = (count) => `named in ${count} ${count === 1 ? 'speaker' : 'speakers'}`;

  function choose(other) {
    target = other;
    // A member's name usually wins; otherwise the longer, fuller name.
    if (voice.member !== other.member) name = voice.member ? voice.name : other.name;
    else name = other.name.length >= voice.name.length ? other.name : voice.name;
    error = '';
  }

  function merge() {
    if (!target || merging) return;
    const kept = target;
    merging = true;
    error = '';
    router.post(
      `${base}/${voice.id}/merge`,
      { into: kept.id, name },
      {
        preserveScroll: true,
        onSuccess: () => onMerged(kept.id),
        onError: (errors) => {
          error = errors.merge || 'Those speakers could not be merged. Please try again.';
        },
        onFinish: () => {
          merging = false;
        },
      }
    );
  }
</script>

<div class="rounded-md border p-3 space-y-2 text-sm" data-testid="voice-merge-panel">
  {#if !target}
    <p class="font-medium">Merge {voice.name} with…</p>
    <div class="relative">
      <MagnifyingGlass class="absolute left-2.5 top-1/2 -translate-y-1/2 size-4 text-muted-foreground" />
      <Input
        bind:value={search}
        aria-label="Search for the other speaker"
        placeholder="Search speakers…"
        class="pl-8 h-8 text-sm" />
    </div>
    <ul class="rounded-md border divide-y max-h-60 overflow-y-auto">
      {#each candidates as other (other.id)}
        <li>
          <button
            type="button"
            class="w-full text-left px-3 py-1.5 hover:bg-muted/50"
            data-testid="voice-merge-candidate"
            onclick={() => choose(other)}>
            <span class="font-medium">{other.name}</span>
            {#if other.member}<span class="ml-1 text-xs text-muted-foreground">member</span>{/if}
            <span class="block text-xs text-muted-foreground">{usedLine(other.used_in)}</span>
          </button>
        </li>
      {:else}
        <li class="px-3 py-1.5 text-muted-foreground">No matching speakers.</li>
      {/each}
    </ul>
    <Button size="sm" variant="ghost" onclick={onCancel}>Cancel</Button>
  {:else}
    <p>
      <span class="font-medium">{voice.name}</span> and <span class="font-medium">{target.name}</span>
      become one speaker. Every transcript naming either shows the kept name, and their samples are pooled into one voice.
    </p>
    <fieldset class="space-y-1" disabled={merging}>
      <legend class="text-xs text-muted-foreground">Keep the name</legend>
      {#each [target.name, voice.name] as option (option)}
        <label class="flex items-center gap-2">
          <input type="radio" name="merge-name" value={option} bind:group={name} />
          {option}
        </label>
      {/each}
    </fieldset>
    {#if error}<p class="text-xs text-destructive" role="alert">{error}</p>{/if}
    <div class="flex gap-2">
      <Button size="sm" disabled={merging || !name} onclick={merge} data-testid="voice-merge-confirm">Merge</Button>
      <Button size="sm" variant="ghost" disabled={merging} onclick={() => (target = null)}>Back</Button>
      <Button size="sm" variant="ghost" disabled={merging} onclick={onCancel}>Cancel</Button>
    </div>
  {/if}
</div>
