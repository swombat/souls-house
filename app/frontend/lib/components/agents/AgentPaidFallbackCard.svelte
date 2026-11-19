<script>
  import { onMount } from 'svelte';
  import * as Alert from '$lib/components/shadcn/alert';
  import { Button } from '$lib/components/shadcn/button';
  import * as Card from '$lib/components/shadcn/card';
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';
  import * as Select from '$lib/components/shadcn/select';
  import { Switch } from '$lib/components/shadcn/switch';
  import { csrfToken } from '$lib/chat-utils';

  // The owner's opt-in for a resident's paid fallback (#690): when the
  // subscription's allowance runs out before a turn starts, the turn runs on a
  // model the owner picks, paid by the account's own OpenRouter key, under a
  // cap. Off until the owner turns it on; hidden while the house hasn't opened
  // the feature.
  let { url, agentName = 'This resident' } = $props();

  // This card saves separately. Keep the cap input's native number validation
  // out of the resident form; the switch and selects have no submission names.
  const DETACHED = 'paid-fallback-detached';
  const PERIODS = [
    { value: 'week', label: 'week (from Monday, UTC)' },
    { value: 'month', label: 'month (from the 1st, UTC)' },
  ];

  let policy = $state(null);
  let loadError = $state('');
  let saveError = $state('');
  let saving = $state(false);
  let saved = $state(false);
  let enabled = $state(false);
  let modelId = $state('');
  let capUsd = $state('');
  let capPeriod = $state('month');
  let modelLabel = $derived(policy?.model_choices.find((choice) => choice.model_id === modelId)?.label);
  let periodLabel = $derived(PERIODS.find((period) => period.value === capPeriod)?.label);

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
  <Alert.Root variant="destructive"><Alert.Description>{loadError}</Alert.Description></Alert.Root>
{:else if policy?.available && !policy.imported_home}
  <Card.Root data-testid="paid-fallback-card">
    <Card.Header>
      <Card.Title class="text-lg">Paid fallback</Card.Title>
      <Card.Description>
        When the subscription's allowance runs out before a turn starts, {agentName} can answer that turn on a model you
        choose instead of going quiet until the allowance resets. It is paid by this account's own OpenRouter key, not by
        your plan, and it never runs past the cap you set.
      </Card.Description>
    </Card.Header>
    <Card.Content class="space-y-4">
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
          Everything {agentName} posts in a conversation while running on the fallback is labelled with the model and who
          pays. The first paid call in each {capPeriod} (and the first after you turn it on) sends you an email.
        </p>
      </div>

      <div class="flex items-center justify-between gap-3 rounded-md border bg-muted/30 p-4">
        <div class="space-y-1">
          <Label for="paid-fallback-enabled" id="paid-fallback-enabled-label">
            Answer on the paid fallback when the allowance runs out
          </Label>
          <p id="paid-fallback-enabled-description" class="text-sm text-muted-foreground">
            Off by default. Only the account's owner can change this.
          </p>
        </div>
        <Switch
          id="paid-fallback-enabled"
          aria-labelledby="paid-fallback-enabled-label"
          checked={enabled}
          onCheckedChange={(on) => (enabled = on)}
          data-testid="paid-fallback-enabled" />
      </div>

      <div class="grid gap-4 sm:grid-cols-2">
        <div class="grid min-w-0 gap-2 sm:col-span-2">
          <Label for="paid-fallback-model">Model</Label>
          <Select.Root type="single" bind:value={modelId} allowDeselect={false}>
            <Select.Trigger id="paid-fallback-model" class="h-9 w-full" data-testid="paid-fallback-model">
              <span class="truncate">{modelLabel ?? 'Select a model'}</span>
            </Select.Trigger>
            <Select.Content>
              {#each policy.model_choices as choice (choice.model_id)}
                <Select.Item value={choice.model_id} label={choice.label}>{choice.label}</Select.Item>
              {/each}
            </Select.Content>
          </Select.Root>
        </div>
        <div class="grid min-w-0 gap-2">
          <Label for="paid-fallback-cap">Cap (USD)</Label>
          <Input
            id="paid-fallback-cap"
            form={DETACHED}
            type="number"
            min="0.01"
            step="0.01"
            bind:value={capUsd}
            data-testid="paid-fallback-cap" />
        </div>
        <div class="grid min-w-0 gap-2">
          <Label for="paid-fallback-period">Per</Label>
          <Select.Root type="single" bind:value={capPeriod} allowDeselect={false}>
            <Select.Trigger id="paid-fallback-period" class="h-9 w-full">
              <span class="truncate">{periodLabel}</span>
            </Select.Trigger>
            <Select.Content>
              {#each PERIODS as period (period.value)}
                <Select.Item value={period.value} label={period.label}>{period.label}</Select.Item>
              {/each}
            </Select.Content>
          </Select.Root>
        </div>
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
        <Alert.Root variant="destructive"><Alert.Description>{saveError}</Alert.Description></Alert.Root>
      {/if}
    </Card.Content>
    <Card.Footer class="gap-3">
      <Button type="button" onclick={save} disabled={saving} data-testid="paid-fallback-save">
        {saving ? 'Saving…' : 'Save paid fallback'}
      </Button>
      {#if saved}<span class="text-sm text-muted-foreground">Saved.</span>{/if}
    </Card.Footer>
  </Card.Root>
{/if}
