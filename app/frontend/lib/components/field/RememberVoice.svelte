<script>
  // "Remember this voice" (spec §9, "Remembering a voice is its own act").
  // Naming is never remembering: this is a separate agreement, unticked every
  // time, then a preview of exactly what would be kept, then "Use it".
  //
  // The server records this agreement as FieldVoiceprints::CONSENT_TEXT_VERSION
  // ("2026-10-08"). If the wording below changes, that version should too.
  import { Link, router } from '@inertiajs/svelte';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import VoiceMeaning from '$lib/components/field/VoiceMeaning.svelte';

  let { speaker, accountId, recordingId, isMe = false } = $props();

  const name = $derived(speaker.name);
  const pending = $derived(speaker.pending_enrolment);
  const voicesUrl = $derived(`/accounts/${accountId}/field/voices`);
  const showOffer = $derived(speaker.can_remember && !pending && !speaker.remembering);
  const offerLabel = $derived(
    isMe
      ? speaker.remembered
        ? 'Remember my voice from this recording instead…'
        : 'Remember my voice…'
      : speaker.remembered
        ? `Remember ${name}'s voice from this recording instead…`
        : `Remember ${name}'s voice…`
  );
  const sampleSeconds = $derived(pending ? Math.round((pending.sample_ms || 0) / 1000) : 0);

  let open = $state(false);
  let agreed = $state(false);
  let busy = $state(false);
  let error = $state('');

  // Unticked every time it opens.
  $effect(() => {
    if (open) {
      agreed = false;
      error = '';
    }
  });

  function begin() {
    if (!agreed) return;
    busy = true;
    error = '';
    router.post(
      `/accounts/${accountId}/field/recordings/${recordingId}/speakers/${speaker.id}/enrolments`,
      { enrolment: { consent: '1' } },
      {
        preserveScroll: true,
        preserveState: true,
        onSuccess: () => (open = false),
        onError: (errors) => (error = errors.enrolment || 'That could not be started. Please try again.'),
        onFinish: () => (busy = false),
      }
    );
  }

  function useIt() {
    busy = true;
    error = '';
    router.post(
      `/accounts/${accountId}/field/enrolments/${pending.id}/confirm`,
      {},
      {
        preserveScroll: true,
        onError: (errors) => (error = errors.enrolment || 'That could not be saved. Please try again.'),
        onFinish: () => (busy = false),
      }
    );
  }

  function notThem() {
    busy = true;
    error = '';
    router.delete(`/accounts/${accountId}/field/enrolments/${pending.id}`, {
      preserveScroll: true,
      onError: (errors) => (error = errors.enrolment || 'That could not be undone. Please try again.'),
      onFinish: () => (busy = false),
    });
  }
</script>

{#if pending}
  <div class="rounded-md border px-2 py-2 text-sm space-y-2" data-testid="voice-preview">
    <p>This is what will be remembered as {isMe ? 'you' : name}.</p>
    <audio src={pending.sample_url} controls preload="metadata" class="w-full h-9"></audio>
    <p class="text-xs text-muted-foreground">{sampleSeconds} s of clear speech</p>
    <div class="flex gap-1">
      <Button size="sm" variant="outline" disabled={busy} onclick={useIt}>Use it</Button>
      <Button size="sm" variant="ghost" disabled={busy} onclick={notThem}>Not them</Button>
    </div>
    {#if error}<p class="text-xs text-destructive" role="alert">{error}</p>{/if}
  </div>
{/if}

{#if speaker.remembering}
  <p class="text-xs text-muted-foreground" data-testid="voice-status">
    Remembering {isMe ? 'your' : `${name}'s`} voice…
  </p>
{:else if speaker.remembered}
  <p class="text-xs text-muted-foreground" data-testid="voice-status">
    This Field remembers {isMe ? 'your' : `${name}'s`} voice ·
    <Link href={voicesUrl} class="underline underline-offset-2 hover:text-foreground">Voices</Link>
  </p>
{/if}

{#if showOffer}
  <button
    type="button"
    class="block text-xs text-foreground/80 underline decoration-dotted underline-offset-2 hover:text-foreground"
    onclick={() => (open = true)}
    data-testid="remember-voice">
    {offerLabel}
  </button>

  <Dialog.Root bind:open>
    <Dialog.Content class="sm:max-w-md">
      <Dialog.Header>
        <Dialog.Title>{isMe ? 'Remember my voice' : `Remember ${name}'s voice`}</Dialog.Title>
      </Dialog.Header>
      <div class="space-y-4" data-testid="remember-voice-panel">
        <label class="flex items-start gap-3 text-sm leading-relaxed cursor-pointer">
          <input
            type="checkbox"
            bind:checked={agreed}
            class="mt-1 size-4 shrink-0 accent-primary"
            data-testid="remember-voice-consent" />
          {#if isMe}
            <span><strong>Remember my voice</strong> so this Field can suggest me in later recordings.</span>
          {:else}
            <span>
              <strong>Remember {name}'s voice</strong> so this Field can suggest them in later recordings.
              <em class="font-sans italic">Only tick this if {name} has agreed.</em>
            </span>
          {/if}
        </label>
        <details class="rounded-md bg-muted/50 px-3 py-2">
          <summary class="cursor-pointer text-sm font-medium">What this means</summary>
          <div class="pt-2">
            <VoiceMeaning whose={isMe ? 'your voice' : `${name}'s voice`} {voicesUrl} />
          </div>
        </details>
        {#if error}<p class="text-sm text-destructive" role="alert">{error}</p>{/if}
      </div>
      <Dialog.Footer>
        <Button variant="ghost" onclick={() => (open = false)}>Cancel</Button>
        <Button disabled={!agreed || busy} onclick={begin} data-testid="remember-voice-continue">Continue</Button>
      </Dialog.Footer>
    </Dialog.Content>
  </Dialog.Root>
{/if}
