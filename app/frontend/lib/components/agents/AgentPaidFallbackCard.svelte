<script>
  import { onMount } from 'svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { csrfToken } from '$lib/chat-utils';

  // The owner's opt-in for a resident's paid fallback (#690): when the
  // subscription's allowance runs out before a turn starts, the turn runs on a
  // model the owner picks, paid by the account's own OpenRouter key, under a
  // cap. Off until the owner turns it on; hidden while the house hasn't opened
  // the feature.
  let { url, agentName = 'This resident' } = $props();

  // The card sits inside the resident settings form but saves on its own:
  // its fields name a form that doesn't exist, so they have no form owner and
  // "Update Resident" neither validates nor submits them.
  const DETACHED = 'paid-fallback-detached';

  let policy = $state(null);
  let loadError = $state('');
  let saveError = $state('');
  let saving = $state(false);
  let saved = $state(false);
  let enabled = $state(false);
  let modelId = $state('');
  let capUsd = $state('');
  let capPeriod = $state('month');

  function adopt(json) {
    policy = json;
    enabled = json.enabled;
    modelId = json.model_id || json.model_choices?.[0]?.model_id || '';
    capUsd = json.cap_usd || '';
    capPeriod = json.cap_period || 'month';
  }

  async function load() {
    loadError = '';
    try {
      const response = await fetch(url, { headers: { Accept: 'application/json' } });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      adopt(await response.json());
    } catch (error) {
      loadError = `Couldn't load the paid fallback settings (${error.message}).`;
    }
  }

  async function save() {
    saving = true;
    saved = false;
    saveError = '';
    try {
      const response = await fetch(url, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json', 'X-CSRF-Token': csrfToken() },
        body: JSON.stringify({
          fallback_policy: { enabled, model_id: modelId, cap_usd: capUsd, cap_period: capPeriod },
        }),
      });
      const json = await response.json();
      if (!response.ok) {
        saveError = json.error || `Couldn't save (HTTP ${response.status}).`;
        return;
      }
      adopt(json);
      saved = true;
    } catch (error) {
      saveError = `Couldn't save (${error.message}).`;
    } finally {
      saving = false;
    }
  }

  function date(value) {
    return value
      ? new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeZone: 'UTC' }).format(new Date(value))
      : null;
  }

  onMount(load);
</script>

{#if loadError}
  <div class="border rounded-lg p-6 text-sm text-destructive" role="alert">{loadError}</div>
{:else if policy?.available && !policy.imported_home}
  <div class="border rounded-lg p-6 space-y-4" data-testid="paid-fallback-card">
    <div class="space-y-1">
      <h2 class="text-lg font-semibold">Paid fallback</h2>
      <p class="text-sm text-muted-foreground">
        When the subscription's allowance runs out before a turn starts, {agentName} can answer that turn on a model you
        choose instead of going quiet until the allowance resets. It is paid by this account's own OpenRouter key, not by
        your plan, and it never runs past the cap you set.
      </p>
    </div>

    <div class="rounded border bg-muted/30 p-3 text-sm space-y-2">
      <p>
        <strong>You need your own OpenRouter account.</strong> Create a key at openrouter.ai and add it under
        <a class="underline" href={policy.api_keys_url}>Model API keys</a>. To pay Anthropic directly for Claude, add
        your Anthropic key to OpenRouter as a BYOK key; OpenRouter then adds its fee to Anthropic's price.
      </p>
      {#if !policy.payer_key_present}
        <p class="text-destructive" data-testid="paid-fallback-no-key">
          This account has no OpenRouter key of its own yet, so the fallback can't run.
        </p>
      {/if}
      <p class="text-muted-foreground">
        The cap covers the fallback's own answers. Tools {agentName} runs with the account's OpenRouter key at any time,
        such as image generation, are ordinary key usage and are not counted against it.
      </p>
      <p class="text-muted-foreground">
        Everything {agentName} posts in a conversation while running on the fallback is labelled with the model and who pays.
        The first paid call in each {capPeriod} (and the first after you turn it on) sends you an email.
      </p>
    </div>

    <label class="flex items-start gap-3">
      <input form={DETACHED} type="checkbox" class="mt-1" bind:checked={enabled} data-testid="paid-fallback-enabled" />
      <span class="text-sm">
        <span class="font-medium">Answer on the paid fallback when the allowance runs out</span>
        <span class="block text-muted-foreground">Off by default. Only the account's owner can change this.</span>
      </span>
    </label>

    <div class="grid gap-4 sm:grid-cols-3">
      <label class="space-y-1 text-sm sm:col-span-1">
        <span class="font-medium">Model</span>
        <select
          form={DETACHED}
          class="w-full rounded border bg-background p-2"
          bind:value={modelId}
          data-testid="paid-fallback-model">
          {#each policy.model_choices as choice (choice.model_id)}
            <option value={choice.model_id}>{choice.label}</option>
          {/each}
        </select>
      </label>
      <label class="space-y-1 text-sm">
        <span class="font-medium">Cap (USD)</span>
        <input
          form={DETACHED}
          type="number"
          min="0.01"
          step="0.01"
          class="w-full rounded border bg-background p-2"
          bind:value={capUsd}
          data-testid="paid-fallback-cap" />
      </label>
      <label class="space-y-1 text-sm">
        <span class="font-medium">Per</span>
        <select form={DETACHED} class="w-full rounded border bg-background p-2" bind:value={capPeriod}>
          <option value="week">week (from Monday, UTC)</option>
          <option value="month">month (from the 1st, UTC)</option>
        </select>
      </label>
    </div>

    {#if policy.enabled || Number(policy.committed_usd) > 0}
      <p class="text-sm text-muted-foreground" data-testid="paid-fallback-spend">
        ${policy.committed_usd} committed this {policy.cap_period}{policy.cap_usd ? ` of $${policy.cap_usd}` : ''},
        until
        {date(policy.period_ends_at)}.
        {#if policy.use_notice_at}
          First used {date(policy.use_notice_at)}.
        {/if}
      </p>
    {/if}
    {#if policy.enabled && policy.status_reason}
      <p class="text-sm text-destructive">{policy.status_reason}</p>
    {/if}

    {#if saveError}
      <p class="text-sm text-destructive" role="alert">{saveError}</p>
    {/if}
    <div class="flex items-center gap-3">
      <Button type="button" onclick={save} disabled={saving} data-testid="paid-fallback-save">
        {saving ? 'Saving…' : 'Save paid fallback'}
      </Button>
      {#if saved}<span class="text-sm text-muted-foreground">Saved.</span>{/if}
    </div>
  </div>
{/if}
