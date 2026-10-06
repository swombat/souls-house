<script>
  import { Input } from '$lib/components/shadcn/input';
  import { Button } from '$lib/components/shadcn/button';
  import { siteName } from '$lib/branding';

  const VISIBLE_LIMIT = 50;
  // Mirrors Agent::Subagents on the server.
  const MAX_MODELS = 50;
  const MODEL_KEY = /^[a-z]+:[A-Za-z0-9][A-Za-z0-9._/:[\]@-]{0,199}$/;

  let {
    enabled = $bindable(false),
    models = $bindable([]),
    catalog = [],
    emptyReason = null,
    providers = [],
    serverErrors = [],
  } = $props();

  let filterText = $state('');
  let customProvider = $state('');
  let customModelId = $state('');
  let customError = $state('');

  let allowedSet = $derived(new Set(models));
  function providerForKey(key) {
    return providers.find((provider) => key.startsWith(`${provider.provider}:`));
  }
  let allowedEntries = $derived(
    models.map((key) => {
      const entry = catalog.find((candidate) => candidate.key === key);
      if (entry) return { ...entry, kind: 'catalog' };
      const provider = providerForKey(key);
      if (provider) {
        return {
          key,
          label: key.slice(provider.provider.length + 1),
          provider_label: provider.provider_label,
          source: provider.source,
          kind: 'custom',
        };
      }
      return { key, label: key, kind: 'unavailable' };
    })
  );
  let availableCatalog = $derived(catalog.filter((entry) => !allowedSet.has(entry.key)));
  let filteredCatalog = $derived.by(() => {
    const term = filterText.trim().toLowerCase();
    if (!term) return availableCatalog;
    return availableCatalog.filter((entry) =>
      [entry.label, entry.model, entry.provider_label, entry.provider].some((field) =>
        (field || '').toLowerCase().includes(term)
      )
    );
  });
  let visibleCatalog = $derived(filteredCatalog.slice(0, VISIBLE_LIMIT));
  let truncated = $derived(filteredCatalog.length > VISIBLE_LIMIT);
  let groupedVisible = $derived.by(() => {
    const groups = new Map();
    for (const entry of visibleCatalog) {
      const groupLabel = entry.provider_label || entry.provider || 'Other';
      if (!groups.has(groupLabel)) groups.set(groupLabel, []);
      groups.get(groupLabel).push(entry);
    }
    return groups;
  });

  let atLimit = $derived(models.length >= MAX_MODELS);

  function addModel(key) {
    if (!allowedSet.has(key) && !atLimit) models = [...models, key];
  }

  function removeModel(key) {
    models = models.filter((candidate) => candidate !== key);
  }

  function addCustomModel() {
    customError = '';
    const trimmedId = customModelId.trim();
    if (!customProvider) {
      customError = 'Choose a provider.';
    } else if (!trimmedId) {
      customError = 'Enter a model ID.';
    } else if (/\s/.test(trimmedId)) {
      customError = 'Model ID cannot contain spaces.';
    } else if (!MODEL_KEY.test(`${customProvider}:${trimmedId}`)) {
      customError = 'Model IDs may use letters, digits and . _ / : [ ] @ - only.';
    } else if (allowedSet.has(`${customProvider}:${trimmedId}`)) {
      customError = 'That model is already allowed.';
    } else if (atLimit) {
      customError = `At most ${MAX_MODELS} models can be allowed.`;
    } else {
      models = [...models, `${customProvider}:${trimmedId}`];
      customModelId = '';
    }
  }
</script>

<div class="space-y-6">
  <div>
    <h2 class="text-lg font-semibold">Sub-agents</h2>
    <p class="text-sm text-muted-foreground">Let this resident delegate bounded, parallel subtasks to sub-agents.</p>
  </div>

  {#if serverErrors.length > 0}
    <div role="alert" class="rounded border border-destructive/50 bg-destructive/5 p-3 text-sm text-destructive">
      {#each serverErrors as message (message)}
        <p>Sub-agent models {message}.</p>
      {/each}
    </div>
  {/if}

  <div class="flex items-start gap-3 rounded border bg-muted/30 p-4">
    <input
      id="subagents_enabled"
      type="checkbox"
      class="mt-1"
      checked={enabled}
      onchange={(event) => (enabled = event.currentTarget.checked)} />
    <div class="space-y-1">
      <label for="subagents_enabled" class="text-sm font-medium">Allow this resident to use sub-agents</label>
      <p class="text-sm text-muted-foreground">
        When on, {$siteName} tells the resident it has standing permission to delegate bounded, parallel subtasks to sub-agents,
        limited to the models listed below. When off, the resident only delegates when someone explicitly asks in the conversation.
      </p>
    </div>
  </div>

  {#if enabled}
    <div class="space-y-4 border-t pt-4">
      <div>
        <h3 class="text-sm font-semibold">Allowed sub-agent models</h3>
        <p class="text-sm text-muted-foreground">Sub-agents spawned by this resident may only use the models below.</p>
      </div>

      {#if models.length === 0}
        <p class="text-sm text-muted-foreground">
          No models allowed yet. The resident will not spawn sub-agents until you add at least one. To let it use its
          own model, add that model too.
        </p>
      {:else}
        <div class="space-y-2">
          {#each allowedEntries as entry (entry.key)}
            <div class="flex items-center justify-between gap-4 rounded border bg-background px-3 py-2">
              <div class="min-w-0">
                <p class="truncate text-sm font-medium">{entry.label}</p>
                {#if entry.kind === 'unavailable'}
                  <p class="text-xs text-amber-700">No longer available</p>
                {:else if entry.kind === 'custom'}
                  <p class="text-xs text-muted-foreground">{entry.provider_label} · {entry.source} · custom ID</p>
                {:else}
                  <p class="text-xs text-muted-foreground">{entry.provider_label} · {entry.source}</p>
                {/if}
              </div>
              <Button type="button" variant="outline" size="sm" onclick={() => removeModel(entry.key)}>Remove</Button>
            </div>
          {/each}
        </div>
      {/if}

      {#if catalog.length === 0}
        <p class="text-sm text-muted-foreground">
          {emptyReason || 'No sub-agent models are available to add.'}
        </p>
      {:else}
        <div class="space-y-2">
          <Input
            type="text"
            placeholder="Filter by model, provider, or source"
            bind:value={filterText}
            class="max-w-md" />
          {#if groupedVisible.size === 0}
            <p class="text-sm text-muted-foreground">No matching models.</p>
          {:else}
            <div class="max-h-80 space-y-3 overflow-y-auto rounded-md border p-2">
              {#each [...groupedVisible] as [providerLabel, entries] (providerLabel)}
                <div class="space-y-1">
                  <p class="text-xs font-semibold text-muted-foreground">{providerLabel}</p>
                  {#each entries as entry (entry.key)}
                    <div class="flex items-center justify-between gap-4 rounded px-2 py-1.5 hover:bg-muted/50">
                      <div class="min-w-0">
                        <p class="truncate text-sm">{entry.label}</p>
                        <p class="text-xs text-muted-foreground">{entry.source}</p>
                      </div>
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        disabled={atLimit}
                        onclick={() => addModel(entry.key)}>Add</Button>
                    </div>
                  {/each}
                </div>
              {/each}
            </div>
          {/if}
          {#if truncated}
            <p class="text-xs text-muted-foreground">
              Showing the first {VISIBLE_LIMIT} matches — refine your search to see more.
            </p>
          {/if}
        </div>
      {/if}

      {#if providers.length > 0}
        <div class="space-y-2 border-t pt-3">
          <p class="text-xs font-semibold text-muted-foreground">Add a model by ID</p>
          <div class="flex flex-wrap items-center gap-2">
            <select
              aria-label="Provider"
              class="h-9 rounded-md border bg-transparent px-3 text-sm"
              bind:value={customProvider}>
              <option value="">Provider</option>
              {#each providers as provider (provider.provider)}
                <option value={provider.provider}>{provider.provider_label}</option>
              {/each}
            </select>
            <Input type="text" placeholder="Model ID" bind:value={customModelId} class="max-w-xs" />
            <Button type="button" variant="outline" size="sm" onclick={addCustomModel}>Add</Button>
          </div>
          {#if customError}
            <p class="text-xs text-destructive">{customError}</p>
          {/if}
        </div>
      {/if}
    </div>
  {/if}
</div>
