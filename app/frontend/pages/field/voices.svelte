<script>
  // The voices this Field knows (spec §7, §9; learning in the house, spec
  // 2026-10-19). Names live here whatever the recognition setting says.
  // Forgetting is never gated: "Forget voice" and "Forget all voices" show
  // whenever something is remembered, even with recognition off.
  import { router } from '@inertiajs/svelte';
  import { createDynamicSync } from '$lib/use-sync';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Switch } from '$lib/components/shadcn/switch';
  import VoiceMeaning from '$lib/components/field/VoiceMeaning.svelte';
  import VoiceSamples from '$lib/components/field/VoiceSamples.svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import { CaretLeft, MagnifyingGlass } from 'phosphor-svelte';

  let {
    voices = [],
    recognise_voices = true,
    house_recognition = false,
    can_change_setting = false,
    account,
  } = $props();

  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({ [`FieldVoiceActivity:${account.id}`]: ['voices', 'recognise_voices', 'can_change_setting'] });
  });

  const base = $derived(`/accounts/${account.id}/field/voices`);
  const anyRemembered = $derived(voices.some((voice) => voice.remembered));
  let search = $state('');

  // The roster has to cope with dozens of speakers, most of them name-only.
  // Tabs split them by what needs doing; search looks across all of them.
  const needsReview = (voice) => (voice.unconfirmed_samples || 0) > 0;
  const hasSamples = (voice) => (voice.samples || 0) > 0;
  const FILTERS = [
    { id: 'review', label: 'Needs review', test: needsReview },
    { id: 'samples', label: 'With samples', test: hasSamples },
    { id: 'names', label: 'Name only', test: (voice) => !hasSamples(voice) },
    { id: 'all', label: 'All', test: () => true },
  ];
  let chosenFilter = $state(null);
  const filter = $derived(
    chosenFilter ?? (voices.some(needsReview) ? 'review' : voices.some(hasSamples) ? 'samples' : 'all')
  );
  const filterCounts = $derived(
    Object.fromEntries(FILTERS.map((option) => [option.id, voices.filter(option.test).length]))
  );
  const matchingVoices = $derived.by(() => {
    const query = search.trim().toLocaleLowerCase();
    const test = query ? () => true : FILTERS.find((option) => option.id === filter).test;
    const rows = voices.filter((voice) => test(voice) && voice.name.toLocaleLowerCase().includes(query));
    if (filter === 'review' && !query) {
      return [...rows].sort((a, b) => b.unconfirmed_samples - a.unconfirmed_samples || a.name.localeCompare(b.name));
    }
    return rows;
  });

  // The selected speaker lives in ?voice= so a link opens straight onto it.
  // On a wide screen the first listed speaker shows until one is picked; on a
  // phone the list shows until one is picked.
  let pickedId = $state(
    typeof window === 'undefined' ? null : new URLSearchParams(window.location.search).get('voice')
  );
  const picked = $derived(voices.find((voice) => voice.id === pickedId) || null);
  const selected = $derived(picked || matchingVoices[0] || null);

  function pick(voice) {
    pickedId = voice?.id ?? null;
    const url = new URL(window.location.href);
    if (pickedId) url.searchParams.set('voice', pickedId);
    else url.searchParams.delete('voice');
    window.history.replaceState(window.history.state, '', url);
  }

  const unprepared = $derived(voices.reduce((sum, voice) => sum + (voice.unprepared_samples || 0), 0));
  let preparing = $state(false);
  let prepareNote = $state('');

  async function prepareAll() {
    preparing = true;
    prepareNote = '';
    try {
      const response = await fetch(`${base}/prepare_samples`, {
        method: 'POST',
        headers: {
          Accept: 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        },
      });
      if (!response.ok) throw new Error();
      const { queued } = await response.json();
      prepareNote = queued
        ? `Preparing ${queued} ${queued === 1 ? 'sample' : 'samples'} in the background. Each gets a play button when it's ready.`
        : 'Nothing could be prepared: learning is off, or those samples need correcting in their recordings.';
    } catch {
      prepareNote = 'That could not be started. Please try again.';
    } finally {
      preparing = false;
    }
  }

  function dot(voice) {
    if (!voice.remember) return { tone: 'bg-muted-foreground/40', label: 'Forgotten' };
    if (voice.guessing) return { tone: 'bg-emerald-500', label: 'Recognising' };
    if (voice.remembered) return { tone: 'bg-amber-500', label: 'Learning, not recognising yet' };
    return { tone: 'bg-muted-foreground/25', label: 'Name only' };
  }

  let switching = $state(null);
  const recognitionOn = $derived(switching ?? recognise_voices);

  function setRecognition(on) {
    if (!can_change_setting) return;
    const identity = account.id;
    switching = on;
    router.patch(
      `${base}/recognition`,
      { recognise_voices: on },
      {
        preserveScroll: true,
        onFinish: () => {
          if (account.id === identity) switching = null;
        },
      }
    );
  }

  function forgetAll() {
    if (!confirm("Forget every voice this Field remembers? They're deleted now. Names on transcripts stay.")) return;
    router.delete(`${base}/prints`);
  }

  function forget(voice) {
    const message = `Forget ${voice.name}'s voice? The print is deleted now and stops learning. Names on transcripts stay.`;
    if (!confirm(message)) return;
    router.delete(`${base}/${voice.id}/print`);
  }

  function rememberAgain(voice) {
    router.post(`${base}/${voice.id}/remember`, {}, { preserveScroll: true });
  }

  function deleteName(voice) {
    const message = `Delete ${voice.name}? Speakers named ${voice.name} go back to 'Speaker N' everywhere, and any remembered voice is forgotten.`;
    if (!confirm(message)) return;
    router.delete(`${base}/${voice.id}`);
  }

  let editingId = $state(null);
  let draft = $state('');
  let renameError = $state('');
  let renaming = $state(false);
  let editingAccount = $state(account.id);
  let renameRequest = 0;

  $effect(() => {
    if (editingAccount !== account.id || (editingId != null && !voices.some((voice) => voice.id === editingId))) {
      editingAccount = account.id;
      editingId = null;
      draft = '';
      renameError = '';
      renaming = false;
      switching = null;
      renameRequest += 1;
    }
  });

  function startRename(voice) {
    renameRequest += 1;
    editingId = voice.id;
    draft = voice.name;
    renameError = '';
    renaming = false;
  }

  function saveRename(event, voice) {
    event.preventDefault();
    const name = draft.trim();
    if (!name) return;
    const identity = account.id;
    const request = ++renameRequest;
    const current = () => account.id === identity && editingId === voice.id && renameRequest === request;
    renaming = true;
    renameError = '';
    router.patch(
      `${base}/${voice.id}`,
      { field_voice: { name } },
      {
        preserveScroll: true,
        onSuccess: () => {
          if (current() && draft.trim() === name) editingId = null;
        },
        onError: (errors) => {
          if (current()) renameError = errors.name || 'That name could not be saved. Please try again.';
        },
        onFinish: () => {
          if (current()) renaming = false;
        },
      }
    );
  }

  // "Merge with other speaker": one person written down under two names.
  // Pick the other speaker by search, then which of the two names to keep.
  let mergingId = $state(null);
  let mergeSearch = $state('');
  let mergeTarget = $state(null);
  let mergeName = $state('');
  let mergeError = $state('');
  let merging = $state(false);

  const mergeCandidates = $derived.by(() => {
    if (!mergingId) return [];
    const query = mergeSearch.trim().toLocaleLowerCase();
    return voices
      .filter((voice) => voice.id !== mergingId && voice.name.toLocaleLowerCase().includes(query))
      .slice(0, 8);
  });

  $effect(() => {
    if (mergingId != null && !voices.some((voice) => voice.id === mergingId)) cancelMerge();
  });

  function startMerge(voice) {
    editingId = null;
    mergingId = voice.id;
    mergeSearch = '';
    mergeTarget = null;
    mergeName = '';
    mergeError = '';
    merging = false;
  }

  function cancelMerge() {
    mergingId = null;
    mergeTarget = null;
    mergeError = '';
  }

  function chooseMergeTarget(voice, other) {
    mergeTarget = other;
    // A member's name usually wins; otherwise the longer, fuller name.
    if (voice.member !== other.member) mergeName = voice.member ? voice.name : other.name;
    else mergeName = other.name.length >= voice.name.length ? other.name : voice.name;
    mergeError = '';
  }

  function saveMerge(voice) {
    if (!mergeTarget) return;
    merging = true;
    mergeError = '';
    router.post(
      `${base}/${voice.id}/merge`,
      { into: mergeTarget.id, name: mergeName },
      {
        preserveScroll: true,
        onSuccess: () => {
          pickedId = mergeTarget?.id ?? null;
          mergingId = null;
          mergeTarget = null;
        },
        onError: (errors) => {
          mergeError = errors.merge || 'Those speakers could not be merged. Please try again.';
        },
        onFinish: () => {
          merging = false;
        },
      }
    );
  }

  function usedLine(count) {
    return `named in ${count} ${count === 1 ? 'speaker' : 'speakers'}`;
  }

  function learnedLine(voice) {
    if (!voice.remember) return 'Voice forgotten, not learning';
    if (!voice.remembered) return 'Name only so far';
    const recordings = `${voice.recordings} ${voice.recordings === 1 ? 'recording' : 'recordings'}`;
    const seconds = voice.sample_seconds != null ? `, ${voice.sample_seconds} s` : '';
    const state = voice.guessing ? 'suggesting' : 'not yet checked, so not suggesting';
    return `Voice learned from ${recordings}${seconds} · ${state}`;
  }
</script>

<svelte:head>
  <title>Voices · Account settings</title>
</svelte:head>

<AccountSettingsLayout
  {account}
  active="voices"
  title="Voices"
  description="The people named in this Field's recordings, and the samples their voice fingerprints are built from.">
  <div class="rounded-lg border p-3 space-y-2 text-sm" data-testid="voices-setting">
    {#if !house_recognition}
      <p data-testid="voices-house-off">
        Voice recognition isn't running in this house right now. Names you give speakers still work.
      </p>
    {:else}
      <div class="flex items-start gap-3">
        <Switch
          id="recognise_voices"
          checked={recognitionOn}
          disabled={!can_change_setting || switching != null}
          onCheckedChange={setRecognition}
          data-testid="voices-switch" />
        <div class="min-w-0 space-y-0.5">
          <label for="recognise_voices" class="font-medium">
            Learn voices from the names people give, and suggest who's speaking
          </label>
          <p class="text-xs text-muted-foreground">
            A suggestion only: someone still confirms who it is before a name goes on a transcript. Off keeps what was
            learned, unused, and stops learning.
            {#if !can_change_setting}Only people who manage this account can change this.{/if}
          </p>
        </div>
      </div>
    {/if}
    {#if anyRemembered && !house_recognition}
      <p class="text-muted-foreground">Voices already remembered are kept but not used. You can still forget them.</p>
    {:else if anyRemembered && !recognitionOn}
      <p class="text-muted-foreground">Learned voices are kept but not used while this is off.</p>
    {/if}
    {#if anyRemembered || unprepared > 0}
      <div class="flex flex-wrap items-center gap-2">
        {#if unprepared > 0}
          <Button size="sm" disabled={preparing} onclick={prepareAll} data-testid="voices-prepare-all">
            Prepare {unprepared}
            {unprepared === 1 ? 'sample' : 'samples'} for listening
          </Button>
        {/if}
        {#if anyRemembered}
          <Button variant="ghost" size="sm" onclick={forgetAll} data-testid="voices-forget-all"
            >Forget all voices</Button>
        {/if}
      </div>
      {#if unprepared > 0 && !prepareNote}
        <p class="text-xs text-muted-foreground">
          These samples were learned before their source spans were recorded, so they can't be played yet. Preparing
          rebuilds them from the recordings; they stay in the fingerprint, unconfirmed, until you review them.
        </p>
      {/if}
      {#if prepareNote}<p class="text-xs" role="status">{prepareNote}</p>{/if}
    {/if}
  </div>

  {#if voices.length === 0}
    <p class="text-muted-foreground">No voices yet. Name a speaker on a transcript and they'll appear here.</p>
  {:else}
    <div class="grid gap-4 md:grid-cols-[17rem_minmax(0,1fr)] items-start">
      <!-- Roster -->
      <div class="space-y-2 min-w-0 {picked ? 'hidden md:block' : ''}" data-testid="voice-roster">
        <div class="relative">
          <MagnifyingGlass class="absolute left-2.5 top-1/2 -translate-y-1/2 size-4 text-muted-foreground" />
          <Input bind:value={search} aria-label="Search speakers" placeholder="Search speakers…" class="pl-8 h-9" />
        </div>
        <div class="flex flex-wrap gap-1" role="tablist" aria-label="Show speakers">
          {#each FILTERS as option (option.id)}
            <button
              type="button"
              role="tab"
              aria-selected={filter === option.id && !search.trim()}
              class="rounded-full px-2.5 py-1 text-xs border transition-colors
                {filter === option.id && !search.trim()
                ? 'bg-primary text-primary-foreground border-primary'
                : 'text-muted-foreground hover:text-foreground hover:bg-muted'}"
              onclick={() => {
                chosenFilter = option.id;
                search = '';
              }}>
              {option.label} <span class="opacity-70">{filterCounts[option.id]}</span>
            </button>
          {/each}
        </div>
        <ul class="rounded-md border divide-y max-h-[65vh] overflow-y-auto">
          {#each matchingVoices as voice (voice.id)}
            {@const status = dot(voice)}
            <li>
              <button
                type="button"
                class="w-full text-left px-3 py-2 flex items-center gap-2 transition-colors
                  {selected?.id === voice.id ? 'bg-muted' : 'hover:bg-muted/50'}"
                aria-current={selected?.id === voice.id ? 'true' : undefined}
                data-testid="voice-row"
                onclick={() => pick(voice)}>
                <span class="size-2 shrink-0 rounded-full {status.tone}" title={status.label}></span>
                <span class="min-w-0 flex-1">
                  <span class="block truncate text-sm font-medium">
                    {voice.name}{#if voice.member}<span class="ml-1 text-xs font-normal text-muted-foreground"
                        >member</span
                      >{/if}
                  </span>
                  <span class="block truncate text-xs text-muted-foreground">
                    {usedLine(voice.used_in)} · {hasSamples(voice)
                      ? `${voice.samples} ${voice.samples === 1 ? 'sample' : 'samples'}`
                      : status.label}
                  </span>
                </span>
                {#if needsReview(voice)}
                  <span
                    class="shrink-0 rounded-full bg-amber-100 px-1.5 text-xs text-amber-900 dark:bg-amber-900/40 dark:text-amber-100"
                    title="Samples in the fingerprint nobody has confirmed">{voice.unconfirmed_samples}</span>
                {/if}
              </button>
            </li>
          {/each}
        </ul>
        {#if matchingVoices.length === 0}<p class="text-sm text-muted-foreground">No matching speakers.</p>{/if}
      </div>

      <!-- Selected speaker -->
      {#if selected}
        {@const voice = selected}
        <div class="min-w-0 space-y-4 {picked ? '' : 'hidden md:block'}" data-testid="voice-detail">
          {#if picked}
            <button
              type="button"
              class="md:hidden text-sm text-muted-foreground inline-flex items-center gap-1"
              onclick={() => pick(null)}><CaretLeft class="size-4" /> All speakers</button>
          {/if}
          <div class="space-y-1">
            {#if editingId === voice.id}
              <form class="flex gap-2" onsubmit={(event) => saveRename(event, voice)}>
                <Input bind:value={draft} maxlength={100} class="h-8 text-sm" aria-label="Name" />
                <Button type="submit" size="sm" disabled={renaming || !draft.trim()}>Save</Button>
                <Button type="button" size="sm" variant="ghost" onclick={() => (editingId = null)}>Cancel</Button>
              </form>
              {#if renameError}<p class="text-xs text-destructive" role="alert">{renameError}</p>{/if}
            {:else}
              <h2 class="text-xl font-semibold">
                {voice.name}
                {#if voice.member}<span class="ml-1 text-xs font-normal text-muted-foreground">member</span>{/if}
              </h2>
            {/if}
            <p class="text-sm text-muted-foreground">{usedLine(voice.used_in)} · {learnedLine(voice)}</p>
            {#if editingId !== voice.id}
              <div class="flex flex-wrap gap-1 -ml-2">
                <Button size="sm" variant="ghost" onclick={() => startRename(voice)}>Rename</Button>
                {#if voices.length > 1}
                  <Button size="sm" variant="ghost" onclick={() => startMerge(voice)} data-testid="voice-merge"
                    >Merge with other speaker</Button>
                {/if}
                {#if voice.remembered || voice.remember}
                  <Button size="sm" variant="ghost" onclick={() => forget(voice)} data-testid="voice-forget"
                    >Forget voice</Button>
                {:else}
                  <Button size="sm" variant="ghost" onclick={() => rememberAgain(voice)} data-testid="voice-remember"
                    >Remember again</Button>
                {/if}
                <Button size="sm" variant="ghost" class="text-destructive" onclick={() => deleteName(voice)}
                  >Delete name</Button>
              </div>
            {/if}
          </div>
          {#if mergingId === voice.id}
            <div class="rounded-md border p-3 space-y-2 text-sm" data-testid="voice-merge-panel">
              {#if !mergeTarget}
                <p class="font-medium">Merge {voice.name} with…</p>
                <div class="relative">
                  <MagnifyingGlass class="absolute left-2.5 top-1/2 -translate-y-1/2 size-4 text-muted-foreground" />
                  <Input
                    bind:value={mergeSearch}
                    aria-label="Search for the other speaker"
                    placeholder="Search speakers…"
                    class="pl-8 h-8 text-sm" />
                </div>
                <ul class="rounded-md border divide-y max-h-60 overflow-y-auto">
                  {#each mergeCandidates as other (other.id)}
                    <li>
                      <button
                        type="button"
                        class="w-full text-left px-3 py-1.5 hover:bg-muted/50"
                        data-testid="voice-merge-candidate"
                        onclick={() => chooseMergeTarget(voice, other)}>
                        <span class="font-medium">{other.name}</span>
                        {#if other.member}<span class="ml-1 text-xs text-muted-foreground">member</span>{/if}
                        <span class="block text-xs text-muted-foreground">{usedLine(other.used_in)}</span>
                      </button>
                    </li>
                  {:else}
                    <li class="px-3 py-1.5 text-muted-foreground">No matching speakers.</li>
                  {/each}
                </ul>
                <Button size="sm" variant="ghost" onclick={cancelMerge}>Cancel</Button>
              {:else}
                <p>
                  <span class="font-medium">{voice.name}</span> and <span class="font-medium">{mergeTarget.name}</span>
                  become one speaker. Every transcript naming either shows the kept name, and their samples are pooled into
                  one voice.
                </p>
                <fieldset class="space-y-1">
                  <legend class="text-xs text-muted-foreground">Keep the name</legend>
                  {#each [mergeTarget.name, voice.name] as option (option)}
                    <label class="flex items-center gap-2">
                      <input type="radio" name="merge-name" value={option} bind:group={mergeName} />
                      {option}
                    </label>
                  {/each}
                </fieldset>
                {#if mergeError}<p class="text-xs text-destructive" role="alert">{mergeError}</p>{/if}
                <div class="flex gap-2">
                  <Button
                    size="sm"
                    disabled={merging || !mergeName}
                    onclick={() => saveMerge(voice)}
                    data-testid="voice-merge-confirm">Merge</Button>
                  <Button size="sm" variant="ghost" onclick={() => (mergeTarget = null)}>Back</Button>
                  <Button size="sm" variant="ghost" onclick={cancelMerge}>Cancel</Button>
                </div>
              {/if}
            </div>
          {/if}
          <VoiceSamples
            base={`${base}/${voice.id}`}
            name={voice.name}
            version={`${voice.samples}|${voice.included_samples}|${voice.confirmed_samples}|${voice.unprepared_samples}|${voice.learned_at}`}
            onChanged={() => router.reload({ only: ['voices'], preserveScroll: true })} />
        </div>
      {/if}
    </div>
    <p class="text-xs text-muted-foreground">
      Forgetting a voice doesn't change transcripts. Names stay where someone gave them; to remove one, rename or
      un-name that speaker.
    </p>
  {/if}

  <details class="text-sm">
    <summary class="cursor-pointer font-medium">What this means</summary>
    <div class="mt-2"><VoiceMeaning onVoicesPage /></div>
  </details>
</AccountSettingsLayout>
