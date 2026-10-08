<script>
  // The voices this Field knows (spec §7, §9). Names live here whatever the
  // recognition gate says. Forgetting is never gated: "Forget voice" and
  // "Forget all voices" show whenever something is remembered, even when the
  // house has recognition switched off.
  import { Link, router } from '@inertiajs/svelte';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Switch } from '$lib/components/shadcn/switch';
  import VoiceMeaning from '$lib/components/field/VoiceMeaning.svelte';
  import { formatWhen } from '$lib/field';
  import { ArrowLeft } from 'phosphor-svelte';

  let {
    voices = [],
    recognise_voices = false,
    house_recognition = false,
    can_change_setting = false,
    backup_retention_days = null,
    account,
  } = $props();

  const base = $derived(`/accounts/${account.id}/field/voices`);
  const anyRemembered = $derived(voices.some((voice) => voice.remembered));

  let switching = $state(null);
  const recognitionOn = $derived(switching ?? recognise_voices);

  function setRecognition(on) {
    if (!can_change_setting) return;
    switching = on;
    router.patch(
      `${base}/recognition`,
      { recognise_voices: on },
      { preserveScroll: true, onFinish: () => (switching = null) }
    );
  }

  function forgetAll() {
    if (!confirm("Forget every voice this Field remembers? They're deleted now. Names on transcripts stay.")) return;
    router.delete(`${base}/prints`);
  }

  function forget(voice) {
    if (!confirm(`Forget ${voice.name}'s voice? The print is deleted now. Names on transcripts stay.`)) return;
    router.delete(`${base}/${voice.id}/print`);
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

  function startRename(voice) {
    editingId = voice.id;
    draft = voice.name;
    renameError = '';
  }

  function saveRename(event, voice) {
    event.preventDefault();
    const name = draft.trim();
    if (!name) return;
    renaming = true;
    renameError = '';
    router.patch(
      `${base}/${voice.id}`,
      { field_voice: { name } },
      {
        preserveScroll: true,
        onSuccess: () => (editingId = null),
        onError: (errors) => (renameError = errors.name || 'That name could not be saved. Please try again.'),
        onFinish: () => (renaming = false),
      }
    );
  }

  function usedLine(count) {
    return `named in ${count} ${count === 1 ? 'speaker' : 'speakers'}`;
  }

  function rememberedLine(voice) {
    const parts = [
      voice.sample_seconds != null ? `${voice.sample_seconds} s sample` : null,
      voice.remembered_by ? `by ${voice.remembered_by}` : null,
      formatWhen(voice.remembered_at) || null,
    ].filter(Boolean);
    return parts.length ? `Voice remembered (${parts.join(', ')})` : 'Voice remembered';
  }
</script>

<svelte:head>
  <title>Voices · Field</title>
</svelte:head>

<div class="p-8 max-w-3xl mx-auto space-y-6">
  <div>
    <Link
      href={`/accounts/${account.id}/field?tab=recordings`}
      class="text-sm text-muted-foreground hover:text-foreground inline-flex items-center gap-1">
      <ArrowLeft class="size-4" /> Recordings
    </Link>
    <h1 class="text-3xl font-bold mt-2">Voices this Field knows</h1>
    <p class="text-muted-foreground mt-1">
      The names people have given speakers in this Field's recordings. Renaming one changes it everywhere.
    </p>
  </div>

  <Card.Root data-testid="voices-setting">
    <Card.Content class="p-4 space-y-3">
      {#if !house_recognition}
        <p class="text-sm" data-testid="voices-house-off">
          Voice recognition isn't available in this house yet. Names you give speakers still work.
        </p>
      {:else}
        <div class="flex items-start gap-3">
          <Switch
            id="recognise_voices"
            checked={recognitionOn}
            disabled={!can_change_setting || switching != null}
            onCheckedChange={setRecognition}
            data-testid="voices-switch" />
          <div class="space-y-1">
            <label for="recognise_voices" class="text-sm font-medium">
              Suggest who's speaking from voices this Field remembers
            </label>
            <p class="text-xs text-muted-foreground">
              A suggestion only. Someone still confirms who it is before a name goes on a transcript.
            </p>
            {#if !can_change_setting}
              <p class="text-xs text-muted-foreground">Only people who manage this account can change this.</p>
            {/if}
          </div>
        </div>
      {/if}
      {#if anyRemembered && !house_recognition}
        <p class="text-sm text-muted-foreground">Voices already remembered are kept but not used. You can still forget them.</p>
      {:else if anyRemembered && !recognitionOn}
        <p class="text-sm text-muted-foreground">Remembered voices are kept but not used while this is off.</p>
      {/if}
      {#if anyRemembered}
        <div>
          <Button variant="outline" size="sm" onclick={forgetAll} data-testid="voices-forget-all"
            >Forget all voices</Button>
        </div>
      {/if}
    </Card.Content>
  </Card.Root>

  <section class="space-y-2">
    {#if voices.length === 0}
      <p class="text-muted-foreground">No voices yet. Name a speaker on a transcript and they'll appear here.</p>
    {:else}
      <Card.Root>
        <Card.Content class="p-0 divide-y">
          {#each voices as voice (voice.id)}
            <div class="p-4 space-y-2" data-testid="voice-row">
              {#if editingId === voice.id}
                <form class="flex gap-2" onsubmit={(event) => saveRename(event, voice)}>
                  <Input bind:value={draft} maxlength={100} class="h-8 text-sm" aria-label="Name" />
                  <Button type="submit" size="sm" disabled={renaming || !draft.trim()}>Save</Button>
                  <Button type="button" size="sm" variant="ghost" onclick={() => (editingId = null)}>Cancel</Button>
                </form>
                {#if renameError}<p class="text-xs text-destructive" role="alert">{renameError}</p>{/if}
              {:else}
                <p class="font-semibold">
                  {voice.name}
                  {#if voice.member}<span class="ml-1 text-xs font-normal text-muted-foreground">member</span>{/if}
                </p>
              {/if}
              <p class="text-sm text-muted-foreground">
                {usedLine(voice.used_in)} · {voice.remembered ? rememberedLine(voice) : 'Name only'}
              </p>
              {#if editingId !== voice.id}
                <div class="flex flex-wrap gap-1">
                  {#if voice.remembered}
                    <Button size="sm" variant="outline" onclick={() => forget(voice)} data-testid="voice-forget"
                      >Forget voice</Button>
                  {/if}
                  <Button size="sm" variant="ghost" onclick={() => startRename(voice)}>Rename</Button>
                  <Button size="sm" variant="ghost" class="text-destructive" onclick={() => deleteName(voice)}
                    >Delete name</Button>
                </div>
              {/if}
            </div>
          {/each}
        </Card.Content>
      </Card.Root>
      <p class="text-xs text-muted-foreground">
        Forgetting a voice doesn't change transcripts. Names stay where someone gave them; to remove one, rename or
        un-name that speaker.
      </p>
    {/if}
  </section>

  <section class="space-y-2">
    <h2 class="text-lg font-semibold">What this means</h2>
    <p class="text-sm text-muted-foreground">When someone agrees, on a transcript, that this Field should remember a person's voice:</p>
    <VoiceMeaning whose="that person's voice" backupDays={backup_retention_days} onVoicesPage />
  </section>
</div>
