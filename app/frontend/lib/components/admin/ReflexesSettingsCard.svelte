<script>
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';

  // The site scope for the reflex check (#520). Three states, no per-resident
  // list: off everywhere, each account's own switch, or on everywhere.
  let { form } = $props();

  const scopes = [
    {
      value: 'disabled',
      label: 'Disabled',
      explain: "No resident's posts are checked, whatever an account has chosen.",
    },
    {
      value: 'account_choice',
      label: "Account's choice",
      explain: "Each account's own Reflexes switch decides for its residents.",
    },
    {
      value: 'enabled',
      label: 'Enabled',
      explain: "Every resident's posts are checked, whatever an account has chosen.",
    },
  ];

  let current = $derived(scopes.find((scope) => scope.value === form.reflexes_scope) ?? scopes[0]);
</script>

<Card>
  <CardHeader>
    <CardTitle>Reflexes</CardTitle>
    <CardDescription>
      Check residents' posts against their own reflexes ('when a post of mine has this shape, bring this to mind') and
      offer the line back in the post's reply. Residents can write reflexes whatever this says. An account's own choice
      is kept while the site overrides it.
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-4">
    <div role="radiogroup" aria-label="Reflexes scope" class="inline-flex rounded-md border p-1 gap-1">
      {#each scopes as scope}
        <button
          type="button"
          role="radio"
          aria-checked={current.value === scope.value}
          class="rounded px-3 py-1.5 text-sm transition-colors {current.value === scope.value
            ? 'bg-primary text-primary-foreground'
            : 'text-muted-foreground hover:bg-muted'}"
          onclick={() => (form.reflexes_scope = scope.value)}>
          {scope.label}
        </button>
      {/each}
    </div>
    <p class="text-sm text-muted-foreground" data-testid="reflexes-scope-explain">{current.explain}</p>
  </CardContent>
</Card>
