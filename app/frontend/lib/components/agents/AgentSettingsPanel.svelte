<script>
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';
  import { Switch } from '$lib/components/shadcn/switch';
  import AgentModelPanel from '$lib/components/agents/AgentModelPanel.svelte';
  import { siteName } from '$lib/branding';

  let { form, groupedModels = {}, selectedModel = $bindable(), runtimeManaged = false } = $props();
</script>

<div class="space-y-8">
  <div>
    <h2 class="text-lg font-semibold">Settings</h2>
    <p class="text-sm text-muted-foreground">Configure how this resident runs and when it wakes.</p>
  </div>

  <AgentModelPanel {form} {groupedModels} {runtimeManaged} bind:selectedModel />

  {#if runtimeManaged}
    <div class="border rounded-lg p-4 text-sm text-muted-foreground">
      Model and thinking-effort changes take effect on the next trigger; no sandbox rebuild is needed. Tools remain
      managed by the agent's Chaos runtime.
    </div>
  {/if}

  <div class="space-y-4">
    <div>
      <h2 class="text-lg font-semibold">Availability</h2>
      <p class="text-sm text-muted-foreground">Control whether this resident participates in automated activity.</p>
    </div>

    <div class="flex items-center justify-between gap-6 rounded border bg-muted/30 p-4">
      <div class="space-y-1">
        <Label for="active">Active</Label>
        <p class="text-sm text-muted-foreground">Keep this resident available for selection in {$siteName}.</p>
      </div>
      <Switch id="active" checked={$form.agent.active} onCheckedChange={(checked) => ($form.agent.active = checked)} />
    </div>

    <div class="flex items-center justify-between gap-6 rounded border bg-muted/30 p-4">
      <div class="space-y-1">
        <Label for="paused">Paused</Label>
        <p class="text-sm text-muted-foreground">
          Exclude this resident from scheduled and self-directed activity while keeping manual triggers available.
        </p>
      </div>
      <Switch id="paused" checked={$form.agent.paused} onCheckedChange={(checked) => ($form.agent.paused = checked)} />
    </div>
  </div>

  <div class="space-y-4">
    <div>
      <h2 class="text-lg font-semibold">Session continuity</h2>
      <p class="text-sm text-muted-foreground">Choose which Chaos sessions continue across separate triggers.</p>
    </div>

    <div class="flex items-center justify-between gap-6 rounded border bg-muted/30 p-4">
      <div class="space-y-1">
        <Label for="persistent_session">Persistent conversation sessions</Label>
        <p class="text-sm text-muted-foreground">
          Resume each conversation's Chaos session and send only new transcript messages after the first turn.
        </p>
      </div>
      <Switch
        id="persistent_session"
        checked={$form.agent.persistent_session}
        disabled={!runtimeManaged}
        onCheckedChange={(checked) => ($form.agent.persistent_session = checked)} />
    </div>

    <div class="flex items-center justify-between gap-6 rounded border bg-muted/30 p-4">
      <div class="space-y-1">
        <Label for="persistent_wake_session">Persistent heartbeat session</Label>
        <p class="text-sm text-muted-foreground">
          Run heartbeats in one continuing Chaos session instead of starting fresh each time.
        </p>
      </div>
      <Switch
        id="persistent_wake_session"
        checked={$form.agent.persistent_wake_session}
        disabled={!runtimeManaged}
        onCheckedChange={(checked) => ($form.agent.persistent_wake_session = checked)} />
    </div>

    {#if !runtimeManaged}
      <p class="text-xs text-muted-foreground">
        Persistent sessions become available when this resident runs in a Chaos harness.
      </p>
    {/if}
  </div>

  <div class="space-y-4">
    <div>
      <h2 class="text-lg font-semibold">Heartbeat schedule</h2>
      <p class="text-sm text-muted-foreground">Control {$siteName}'s self-directed wakes for this resident.</p>
    </div>

    <div class="flex items-center justify-between gap-6 rounded border bg-muted/30 p-4">
      <div class="space-y-1">
        <Label for="scheduled_wakes_enabled">Scheduled heartbeats</Label>
        <p class="text-sm text-muted-foreground">
          Allow {$siteName} to wake this resident for self-directed heartbeat sessions.
        </p>
      </div>
      <Switch
        id="scheduled_wakes_enabled"
        checked={$form.agent.scheduled_wakes_enabled}
        onCheckedChange={(checked) => ($form.agent.scheduled_wakes_enabled = checked)} />
    </div>

    <div class="rounded border bg-muted/30 p-4 space-y-2">
      <Label for="heartbeat_wakes_per_day">Heartbeat wakes per day</Label>
      <Input
        id="heartbeat_wakes_per_day"
        type="number"
        min={1}
        max={48}
        step={1}
        bind:value={$form.agent.heartbeat_wakes_per_day}
        disabled={!$form.agent.scheduled_wakes_enabled}
        class="max-w-32" />
      <p class="text-sm text-muted-foreground">
        Spread evenly across the UTC day. Use 1 for daily, 2 for twice daily, 24 for hourly, or 48 for every 30 minutes.
      </p>
    </div>
  </div>
</div>
