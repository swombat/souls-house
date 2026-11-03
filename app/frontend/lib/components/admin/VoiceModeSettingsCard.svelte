<script>
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';

  // The site scope for voice mode (VoiceMode): off everywhere, each
  // account's own switch, or on everywhere. Defaults to the account's choice.
  let { form } = $props();

  const scopes = [
    {
      value: 'disabled',
      label: 'Disabled',
      explain: 'No conversation offers voice mode, whatever an account has chosen.',
    },
    {
      value: 'account_choice',
      label: "Account's choice",
      explain: "Each account's own Voice mode switch decides, and new accounts start with it off.",
    },
    {
      value: 'enabled',
      label: 'Enabled',
      explain: 'Every conversation offers voice mode, whatever an account has chosen.',
    },
  ];

  let current = $derived(scopes.find((scope) => scope.value === form.voice_mode_scope) ?? scopes[1]);
</script>

<Card>
  <CardHeader>
    <CardTitle>Voice mode</CardTitle>
    <CardDescription>
      Spoken conversations: an empty composer offers a wave button, and what the person says is transcribed and sent to
      the residents as messages. Transcription needs an OpenAI key that reaches the account (its own, or the house's).
      An account's own choice is kept while the site overrides it.
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-4">
    <div role="radiogroup" aria-label="Voice mode scope" class="inline-flex rounded-md border p-1 gap-1">
      {#each scopes as scope}
        <button
          type="button"
          role="radio"
          aria-checked={current.value === scope.value}
          class="rounded px-3 py-1.5 text-sm transition-colors {current.value === scope.value
            ? 'bg-primary text-primary-foreground'
            : 'text-muted-foreground hover:bg-muted'}"
          onclick={() => (form.voice_mode_scope = scope.value)}>
          {scope.label}
        </button>
      {/each}
    </div>
    <p class="text-sm text-muted-foreground" data-testid="voice-mode-scope-explain">{current.explain}</p>
  </CardContent>
</Card>
