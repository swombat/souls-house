<script>
  let { metadata = null, title = 'Token authority', compact = false } = $props();
  let kind = $derived(metadata?.token_kind || 'unknown');
  let kindLabel = $derived(
    kind === 'fine_grained'
      ? 'Fine-grained personal access token'
      : kind === 'classic'
        ? 'Classic token'
        : 'Unknown token authority'
  );
  let scopes = $derived(Array.isArray(metadata?.oauth_scopes) ? metadata.oauth_scopes : []);
  let authoritySource = $derived(
    metadata?.authority_source === 'token_format'
      ? 'Inferred from token prefix'
      : metadata?.authority_source === 'X-OAuth-Scopes'
        ? 'Reported by GitHub (OAuth scopes header)'
        : 'Not established'
  );
</script>

<section class="space-y-3 rounded-lg border p-4" aria-label={title}>
  <h2 class="font-semibold">{title}</h2>
  <dl class="space-y-2 text-sm">
    <div>
      <dt class="text-muted-foreground">Token type</dt>
      <dd>{kindLabel}</dd>
    </div>
    <div>
      <dt class="text-muted-foreground">Authority source</dt>
      <dd>{authoritySource}</dd>
    </div>
    <div>
      <dt class="text-muted-foreground">Reported OAuth scopes</dt>
      <dd>
        {scopes.length
          ? scopes.join(', ')
          : 'No OAuth scopes reported; this does not establish repository permissions.'}
      </dd>
    </div>
  </dl>
  {#if !compact && metadata?.authority_summary}
    <p class="text-sm">{metadata.authority_summary}</p>
  {/if}
  {#if kind === 'fine_grained' && !compact}
    <p class="text-sm text-muted-foreground">
      A fine-grained token format is not proof of least privilege. Review its selected repositories and permissions in
      GitHub before approval. Connectivity alone does not establish its authority.
    </p>
  {:else if kind !== 'fine_grained'}
    <p role="alert" class="text-sm text-destructive">
      Classic and unknown tokens cannot be used for this import. Connect a repository-specific fine-grained token.
    </p>
  {/if}
  {#if !compact && metadata?.warnings?.length}
    <ul class="list-disc space-y-1 pl-5 text-sm">
      {#each metadata.warnings as warning}
        <li>{warning}</li>
      {/each}
    </ul>
  {/if}
</section>
