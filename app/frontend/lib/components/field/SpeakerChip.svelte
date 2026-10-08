<script>
  import { router } from '@inertiajs/svelte';
  import * as Popover from '$lib/components/shadcn/popover/index.js';
  import { Button, buttonVariants } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { parseNameMatch } from '$lib/field-recordings';

  let { speaker, url, voices = [], members = [], myVoiceId = null, myUserId = null, myName = '' } = $props();

  let open = $state(false);
  let typed = $state('');
  let match = $state(null);
  let error = $state('');
  let busy = $state(false);

  const otherVoices = $derived(voices.filter((voice) => voice.id !== myVoiceId));
  const otherMembers = $derived(members.filter((member) => String(member.user_id) !== String(myUserId)));
  const optionClass = 'w-full text-left rounded px-2 py-1.5 text-sm hover:bg-muted disabled:opacity-50';

  $effect(() => {
    if (!open) {
      match = null;
      error = '';
    }
  });

  function name(choice) {
    busy = true;
    error = '';
    router.patch(
      url,
      { speaker: choice },
      {
        preserveScroll: true,
        preserveState: true,
        onSuccess: () => {
          open = false;
          typed = '';
          match = null;
        },
        onError: (errors) => {
          const asked = parseNameMatch(errors.name_match);
          if (asked) match = { ...asked, typed: choice.name };
          else error = errors.name || 'That name could not be saved. Please try again.';
        },
        onFinish: () => (busy = false),
      }
    );
  }

  function nameTyped(event) {
    event.preventDefault();
    if (typed.trim()) name({ name: typed.trim() });
  }

  function differentName() {
    match = null;
    error = 'Then give this one a different name, so the two stay apart.';
  }
</script>

<Popover.Root bind:open>
  <Popover.Trigger
    class={buttonVariants({ variant: speaker.named ? 'ghost' : 'outline', size: 'sm' })}
    data-testid="speaker-chip">
    {speaker.named ? 'Rename' : "Who's this?"}
  </Popover.Trigger>
  <Popover.Content class="w-64 p-2" align="start">
    {#if match}
      <div class="space-y-2 p-1" data-testid="speaker-name-match">
        <p class="text-sm">
          Same {match.name}{match.last_named_in ? ` as in ${match.last_named_in}` : ' as before'}?
        </p>
        <div class="flex gap-2">
          <Button size="sm" disabled={busy} onclick={() => name({ name: match.typed, link_existing: true })}
            >Yes</Button>
          <Button size="sm" variant="ghost" onclick={differentName}>No</Button>
        </div>
      </div>
    {:else}
      <div class="space-y-0.5">
        <button
          class="{optionClass} font-medium"
          disabled={busy || (myVoiceId && speaker.voice_id === myVoiceId)}
          onclick={() => name({ me: true })}
          data-testid="speaker-choice-me">
          You{myName ? ` (${myName})` : ''}
        </button>
        {#each otherVoices as voice (voice.id)}
          <button
            class={optionClass}
            disabled={busy || voice.id === speaker.voice_id}
            onclick={() => name({ voice_id: voice.id })}>
            {voice.name}
          </button>
        {/each}
        {#each otherMembers as member (member.user_id)}
          <button class={optionClass} disabled={busy} onclick={() => name({ member_user_id: member.user_id })}>
            {member.name}
          </button>
        {/each}
        <form onsubmit={nameTyped} class="flex gap-1 pt-1">
          <Input bind:value={typed} placeholder="Someone else…" maxlength={100} class="h-8 text-sm" />
          <Button type="submit" size="sm" disabled={busy || !typed.trim()}>Name</Button>
        </form>
        {#if speaker.named}
          <button class="{optionClass} text-muted-foreground" disabled={busy} onclick={() => name({ unname: true })}>
            Not named
          </button>
        {/if}
      </div>
    {/if}
    {#if error}
      <p class="text-xs text-destructive p-1" role="alert">{error}</p>
    {/if}
  </Popover.Content>
</Popover.Root>
