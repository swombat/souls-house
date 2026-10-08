<script>
  // Which models people may pick for this resident in a single conversation,
  // and whether the resident may change its own. The backend's rules: same
  // provider as the default model, no house models, the default excluded.
  import { Label } from '$lib/components/shadcn/label';
  import { Switch } from '$lib/components/shadcn/switch';
  import { findModel } from '$lib/agent-models';

  let { form, groupedModels = {}, defaultModelId = null, agentName = 'this resident' } = $props();

  const HOUSE_GROUP = 'On the house';

  const providerOf = (id) => (id && id.includes('/') ? id.slice(0, id.indexOf('/')) : null);
  const isHouse = (id, group) => group === HOUSE_GROUP || providerOf(id) === 'house';

  // House offerings arrive in grouped_models under "On the house", with ids
  // under "house/" (HouseInference::Offering.models).
  const defaultIsHouse = $derived(
    providerOf(defaultModelId) === 'house' ||
      (groupedModels[HOUSE_GROUP] || []).some((m) => m.model_id === defaultModelId)
  );
  const defaultLabel = $derived(findModel(groupedModels, defaultModelId)?.label || defaultModelId);

  // grouped_models lists some models twice (a "Top Models" group and their
  // provider's group), so keep the first entry per id.
  const candidates = $derived.by(() => {
    const family = providerOf(defaultModelId);
    if (!family || defaultIsHouse) return [];
    const seen = new Set();
    const out = [];
    for (const [group, models] of Object.entries(groupedModels)) {
      for (const model of models) {
        if (seen.has(model.model_id)) continue;
        if (isHouse(model.model_id, group)) continue;
        // The server marks models a conversation can actually run on.
        if (model.switchable === false) continue;
        if (model.model_id === defaultModelId || providerOf(model.model_id) !== family) continue;
        seen.add(model.model_id);
        out.push(model);
      }
    }
    return out;
  });

  // Listed ids that are no longer offered here (for example after the default
  // changed provider). Shown so they can be removed; the backend reports them
  // as a problem if a conversation tries to use one.
  const staleIds = $derived(
    ($form.agent.switchable_model_ids || []).filter(
      (id) => id !== defaultModelId && !candidates.some((m) => m.model_id === id)
    )
  );

  function toggle(id, checked) {
    const current = $form.agent.switchable_model_ids || [];
    $form.agent.switchable_model_ids = checked ? [...new Set([...current, id])] : current.filter((x) => x !== id);
  }
</script>

<div class="space-y-4">
  <div>
    <h2 class="text-lg font-semibold">Models for conversations</h2>
    <p class="text-sm text-muted-foreground">
      People in a conversation can pick one of these models from {agentName}'s button in the room. {defaultLabel} stays the
      default. Switching keeps the conversation's session.
    </p>
  </div>

  {#if defaultIsHouse}
    <p class="text-sm text-muted-foreground rounded border bg-muted/30 p-4">
      Conversation models are not available while the default is a house model.
    </p>
  {:else if candidates.length === 0}
    <p class="text-sm text-muted-foreground rounded border bg-muted/30 p-4">
      No other models from the same provider as {defaultLabel} are available.
    </p>
  {:else}
    <fieldset class="rounded border bg-muted/30 p-4">
      <legend class="sr-only">Models people can pick for {agentName} in a conversation</legend>
      <div class="grid gap-2 sm:grid-cols-2">
        {#each candidates as model (model.model_id)}
          <label class="flex items-center gap-2 text-sm cursor-pointer">
            <input
              type="checkbox"
              class="size-4 accent-primary"
              checked={($form.agent.switchable_model_ids || []).includes(model.model_id)}
              onchange={(event) => toggle(model.model_id, event.currentTarget.checked)} />
            <span>{model.label}</span>
          </label>
        {/each}
      </div>
    </fieldset>
  {/if}

  {#if staleIds.length > 0}
    <div
      class="rounded border border-amber-500/60 bg-amber-50 p-3 text-sm text-amber-800 dark:bg-amber-950/30 dark:text-amber-300">
      <p>These listed models no longer match the default model's provider. Conversations cannot use them.</p>
      <ul class="mt-1 space-y-1">
        {#each staleIds as id (id)}
          <li class="flex items-center gap-2">
            <span>{findModel(groupedModels, id)?.label || id}</span>
            <button type="button" class="text-xs underline underline-offset-2" onclick={() => toggle(id, false)}
              >Remove</button>
          </li>
        {/each}
      </ul>
    </div>
  {/if}

  {#if $form.errors?.switchable_model_ids}
    <p class="text-sm text-destructive">{$form.errors.switchable_model_ids}</p>
  {/if}

  <div class="flex items-center justify-between gap-6 rounded border bg-muted/30 p-4">
    <div class="space-y-1">
      <Label for="resident_may_switch_model">Let {agentName} change its own model in a conversation</Label>
      <p class="text-sm text-muted-foreground">
        It picks from the same list. The change applies from its next turn and never starts one.
      </p>
    </div>
    <Switch
      id="resident_may_switch_model"
      checked={$form.agent.resident_may_switch_model}
      onCheckedChange={(checked) => ($form.agent.resident_may_switch_model = checked)} />
  </div>
</div>
