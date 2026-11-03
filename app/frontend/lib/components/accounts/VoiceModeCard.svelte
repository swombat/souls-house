<script>
  import { router } from '@inertiajs/svelte';
  import * as Card from '$lib/components/shadcn/card';
  import { Switch } from '$lib/components/shadcn/switch';
  import { accountPath } from '@/routes';

  // The account's voice mode switch (VoiceMode). siteScope is the site's
  // scope: under 'disabled' or 'enabled' the site overrides this switch, which
  // keeps its value. transcriptionKey says whether an OpenAI key reaches this
  // account (its own, or the house's through the house-keys fall-through);
  // without one the mode is offered but cannot be started.
  let { accountId, enabled, canManage = false, siteScope = 'account_choice', transcriptionKey = false } = $props();

  let override = $derived(
    siteScope === 'disabled'
      ? 'The site has voice mode off for every account, so this switch has no effect for now. Its setting is kept for when the site leaves it to each account.'
      : siteScope === 'enabled'
        ? 'The site has voice mode on for every account, so conversations offer it whatever this switch says. Its setting is kept for when the site leaves it to each account.'
        : null
  );

  let saving = $state(false);

  function toggle(on) {
    if (saving) return;
    saving = true;
    router.put(
      accountPath(accountId),
      { account: { voice_mode_enabled: on } },
      { preserveScroll: true, preserveState: true, onFinish: () => (saving = false) }
    );
  }
</script>

<Card.Root>
  <Card.Header>
    <Card.Title>Voice mode</Card.Title>
    <Card.Description>
      Talk to a conversation instead of typing. With this on, an empty composer offers a wave button; press it and each
      thing you say is transcribed and sent to the residents as a message, hands free, until you end the conversation.
      While you speak, the audio goes from your browser straight to OpenAI's live transcription, using this account's
      OpenAI key or the house's when the account uses house keys; that only decides when you've finished and shows a
      rough caption. Each thing you say is also recorded and sent through the house to ElevenLabs, the same way a voice
      note is, and the message carries that transcript with the recording attached, like any voice note.
    </Card.Description>
  </Card.Header>
  <Card.Content class="space-y-3">
    {#if canManage}
      <label class="flex items-center justify-between gap-3 text-sm">
        <span>Voice mode</span>
        <Switch
          aria-label="Voice mode"
          data-testid="voice-mode-enabled"
          checked={enabled}
          disabled={saving}
          onCheckedChange={toggle} />
      </label>
    {:else}
      <p class="text-sm" data-testid="voice-mode-enabled-readonly">
        {enabled ? 'Voice mode is on for this account.' : 'Voice mode is off for this account.'}
      </p>
    {/if}
    {#if override}
      <p class="text-sm text-muted-foreground" data-testid="voice-mode-site-override">{override}</p>
    {/if}
    {#if !transcriptionKey}
      <p class="text-sm text-muted-foreground" data-testid="voice-mode-no-key">
        No OpenAI key reaches this account, so the wave button will be shown but cannot be pressed. Add an OpenAI key
        under the account's model provider keys, or let the account use the house keys.
      </p>
    {/if}
  </Card.Content>
</Card.Root>
