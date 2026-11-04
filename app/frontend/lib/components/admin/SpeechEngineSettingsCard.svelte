<script>
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';

  // The site scope for the ElevenLabs voice engine (SpeechEngine). Phonon, in
  // the person's browser, is every account's engine unless this offers
  // ElevenLabs. Defaults to Disabled: Phonon everywhere.
  let { form } = $props();

  const scopes = [
    {
      value: 'disabled',
      label: 'Phonon for everyone',
      explain:
        'Every account speaks with Phonon, in the browser. Accounts cannot choose ElevenLabs; a choice they made earlier is kept for when the site offers it again.',
    },
    {
      value: 'account_choice',
      label: "Account's choice",
      explain:
        "Each account chooses Phonon (the default) or ElevenLabs. ElevenLabs needs the account's own ElevenLabs key and only reads Life and Work residents (and residents on the house); Conversation residents speak with Phonon.",
    },
    {
      value: 'enabled',
      label: 'ElevenLabs for everyone',
      explain:
        "Every account speaks with ElevenLabs, whatever it chose. An account without its own ElevenLabs key gets an error instead of speech (the house's key is never used), and Conversation residents still speak with Phonon.",
    },
  ];

  let current = $derived(scopes.find((scope) => scope.value === form.speech_engine_scope) ?? scopes[0]);
</script>

<Card>
  <CardHeader>
    <CardTitle>Voice engine</CardTitle>
    <CardDescription>
      What reads residents' messages aloud, for Listen and in voice mode. Phonon runs in the person's browser on WebGPU
      with no round trip to a server; ElevenLabs is made on its servers, so every reply waits for them and starts much later. There is no
      fallback either way: if the engine an account is on can't speak, the person sees why.
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-4">
    <div role="radiogroup" aria-label="Voice engine scope" class="inline-flex flex-wrap rounded-md border p-1 gap-1">
      {#each scopes as scope}
        <button
          type="button"
          role="radio"
          aria-checked={current.value === scope.value}
          class="rounded px-3 py-1.5 text-sm transition-colors {current.value === scope.value
            ? 'bg-primary text-primary-foreground'
            : 'text-muted-foreground hover:bg-muted'}"
          onclick={() => (form.speech_engine_scope = scope.value)}>
          {scope.label}
        </button>
      {/each}
    </div>
    <p class="text-sm text-muted-foreground" data-testid="speech-engine-scope-explain">{current.explain}</p>
  </CardContent>
</Card>
