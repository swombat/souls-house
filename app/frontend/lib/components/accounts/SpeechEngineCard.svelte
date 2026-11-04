<script>
  import { router } from '@inertiajs/svelte';
  import * as Card from '$lib/components/shadcn/card';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input';
  import { accountPath } from '@/routes';

  // The account's voice engine (SpeechEngine): Phonon, in the person's
  // browser (the default), or ElevenLabs, which the site may offer. siteScope
  // is the site's choice: 'disabled' keeps every account on Phonon, 'enabled'
  // puts every account on ElevenLabs, and only 'account_choice' lets this
  // card decide. keyPresent says whether the account has its own ElevenLabs
  // key; the key itself never comes back to the page.
  let { accountId, engine = 'phonon', canManage = false, siteScope = 'disabled', keyPresent = false } = $props();

  let saving = $state(false);
  let keyDraft = $state('');

  const choosable = $derived(siteScope === 'account_choice');
  const effective = $derived(
    siteScope === 'enabled' ? 'elevenlabs' : siteScope === 'account_choice' ? engine : 'phonon'
  );

  const override = $derived(
    siteScope === 'disabled'
      ? engine === 'elevenlabs'
        ? 'The site has every account on Phonon just now, so this account speaks with Phonon. Its ElevenLabs choice is kept for when the site offers ElevenLabs again.'
        : null
      : siteScope === 'enabled'
        ? "The site has every account on ElevenLabs just now, whatever this account chose. It reads with this account's own ElevenLabs key."
        : null
  );

  function save(attributes, after) {
    if (saving) return;
    saving = true;
    router.put(
      accountPath(accountId),
      { account: attributes },
      {
        preserveScroll: true,
        preserveState: true,
        onSuccess: () => after?.(),
        onFinish: () => (saving = false),
      }
    );
  }

  const choose = (value) => value !== engine && save({ speech_engine: value });
  const saveKey = () => keyDraft.trim() && save({ eleven_labs_api_key: keyDraft.trim() }, () => (keyDraft = ''));
  const removeKey = () => save({ eleven_labs_api_key: '' });
</script>

<Card.Root>
  <Card.Header>
    <Card.Title>Voice engine</Card.Title>
    <Card.Description>
      What reads residents' messages aloud, for Listen and in voice mode. Phonon runs on this device, in the browser,
      with no round trip to a server; the first time it downloads about 52 MB, which the browser then keeps (clearing
      the site's data means downloading it again). It needs a browser with WebGPU. ElevenLabs makes the audio on its
      servers, with this account's own ElevenLabs key. If the engine the account is on can't speak, you see why; it
      never switches to the other one.
    </Card.Description>
  </Card.Header>
  <Card.Content class="space-y-4">
    {#if canManage && choosable}
      <div role="radiogroup" aria-label="Voice engine" class="space-y-2">
        <label class="flex items-start gap-3 text-sm">
          <input
            type="radio"
            name="speech-engine"
            value="phonon"
            data-testid="speech-engine-phonon"
            checked={engine === 'phonon'}
            disabled={saving}
            onchange={() => choose('phonon')} />
          <span
            ><span class="font-medium">Phonon, on this device</span> (default): no voice server in the way, English only.</span>
        </label>
        <label class="flex items-start gap-3 text-sm">
          <input
            type="radio"
            name="speech-engine"
            value="elevenlabs"
            data-testid="speech-engine-elevenlabs"
            checked={engine === 'elevenlabs'}
            disabled={saving}
            onchange={() => choose('elevenlabs')} />
          <span><span class="font-medium">ElevenLabs</span>: needs this account's own ElevenLabs key.</span>
        </label>
      </div>
    {:else}
      <p class="text-sm" data-testid="speech-engine-readonly">
        {effective === 'elevenlabs'
          ? 'This account speaks with ElevenLabs.'
          : 'This account speaks with Phonon, on the device.'}
      </p>
    {/if}

    {#if effective === 'elevenlabs'}
      <p
        class="rounded-md border border-amber-500/40 bg-amber-500/10 p-3 text-sm"
        data-testid="speech-engine-latency-warning">
        ElevenLabs is much slower to start speaking than Phonon on this device: each reply waits for its servers before
        a word is heard. It reads only Life and Work residents (and residents on the house); Conversation residents
        speak with Phonon.
      </p>
    {/if}

    {#if override}
      <p class="text-sm text-muted-foreground" data-testid="speech-engine-site-override">{override}</p>
    {/if}

    {#if canManage && (effective === 'elevenlabs' || engine === 'elevenlabs' || keyPresent)}
      <div class="space-y-2" data-testid="eleven-labs-key">
        <p class="text-sm">
          {keyPresent ? 'This account has its own ElevenLabs key.' : 'This account has no ElevenLabs key of its own.'}
          {#if effective === 'elevenlabs' && !keyPresent}
            <span class="text-destructive">Until one is added, residents can't be read aloud.</span>
          {/if}
        </p>
        <form class="flex gap-2" onsubmit={(event) => (event.preventDefault(), saveKey())}>
          <Input
            type="password"
            autocomplete="off"
            placeholder={keyPresent ? 'Replace the ElevenLabs key' : 'ElevenLabs API key'}
            aria-label="ElevenLabs API key"
            bind:value={keyDraft} />
          <Button type="submit" disabled={saving || !keyDraft.trim()}>Save key</Button>
          {#if keyPresent}
            <Button type="button" variant="outline" disabled={saving} onclick={removeKey}>Remove</Button>
          {/if}
        </form>
      </div>
    {/if}
  </Card.Content>
</Card.Root>
