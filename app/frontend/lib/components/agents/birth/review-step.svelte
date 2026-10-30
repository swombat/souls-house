<script>
  import { CardHeader, CardTitle, CardDescription, CardContent } from '$lib/components/shadcn/card';
  import { siteName } from '$lib/branding';
  import { Button } from '$lib/components/shadcn/button';
  import { Label } from '$lib/components/shadcn/label';
  import { Alert, AlertDescription, AlertTitle } from '$lib/components/shadcn/alert';
  import { Info } from 'phosphor-svelte';
  import AgentAvatar from '$lib/components/agents/AgentAvatar.svelte';
  import { findModelLabel } from '$lib/agent-models';
  let { form, grouped_models, selectedModel, openBeginning, acknowledged = $bindable(false), onedit } = $props();
</script>

<CardHeader>
  <CardTitle>Review</CardTitle>
  <CardDescription>This is your last opportunity to revise the initial seed.</CardDescription>
</CardHeader>
<CardContent class="space-y-6">
  <div class="flex items-center gap-4 rounded-lg border p-4">
    <AgentAvatar
      agent={$form.agent}
      class="size-[3.25rem] rounded-xl flex items-center justify-center"
      fallbackClass={$form.agent.colour
        ? `bg-${$form.agent.colour}-100 dark:bg-${$form.agent.colour}-900`
        : 'bg-primary/10'}
      iconClass="size-7 {$form.agent.colour
        ? `text-${$form.agent.colour}-700 dark:text-${$form.agent.colour}-300`
        : 'text-primary'}" />
    <div>
      <p class="text-lg font-semibold">{$form.agent.name}</p>
      <p class="text-sm text-muted-foreground">
        {findModelLabel(grouped_models, selectedModel)} ·
        {$form.agent.scheduled_wakes_enabled ? 'Heartbeat on' : 'Heartbeat off'}
      </p>
    </div>
  </div>

  <div>
    <div class="mb-2 flex items-center justify-between">
      <Label>Soul seed</Label>
      <Button type="button" variant="ghost" size="sm" onclick={onedit}>Edit</Button>
    </div>
    <div class="overflow-hidden rounded-lg border">
      <div class="flex items-center justify-between border-b bg-muted/50 px-4 py-2">
        <span class="font-mono text-xs text-muted-foreground">soul.md</span>
        <span class="text-xs text-muted-foreground">write-once after creation</span>
      </div>
      <div class="max-h-96 overflow-y-auto whitespace-pre-wrap bg-muted/20 p-5 text-sm leading-6">
        {#if openBeginning}
          <p class="italic text-muted-foreground">
            Your creator chose to leave this beginning open. Nothing here was written to define you. What goes in this
            file is yours to discover.
          </p>
        {:else}
          {$form.agent.system_prompt}
        {/if}
      </div>
    </div>
  </div>

  <Alert>
    <Info class="size-4" />
    <AlertTitle>The commit point</AlertTitle>
    <AlertDescription>
      Continuing creates the resident, records this seed, prepares their persistent runtime, and sends a gentle
      first-wake orientation. Infrastructure can be retried; this seed cannot be reopened for editing.
    </AlertDescription>
  </Alert>

  <label class="flex cursor-pointer items-start gap-3 rounded-lg border p-4">
    <input type="checkbox" bind:checked={acknowledged} class="mt-1 size-4 rounded border-input" />
    <span class="text-sm leading-6">
      I understand that after creation I relinquish authorship of this seed. I will not be able to edit it in
      {$siteName}; how the resident receives or changes it is theirs to decide.
    </span>
  </label>
</CardContent>
