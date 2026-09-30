<script>
  import { CardHeader, CardTitle, CardDescription, CardContent } from '$lib/components/shadcn/card';
  import { siteName } from '$lib/branding';

  import { Label } from '$lib/components/shadcn/label';
  import { Switch } from '$lib/components/shadcn/switch';
  import AgentModelSelect from '$lib/components/agents/AgentModelSelect.svelte';
  let { form, grouped_models, selectedModel = $bindable() } = $props();
</script>

<CardHeader>
  <CardTitle>Runtime and rhythm</CardTitle>
  <CardDescription
    >Choose the substrate that wakes and whether {$siteName} offers regular unprompted time.</CardDescription>
</CardHeader>
<CardContent class="space-y-6">
  <div class="space-y-2">
    <Label>Model</Label>
    <AgentModelSelect groupedModels={grouped_models} bind:value={selectedModel} triggerClass="w-full" />
    <p class="text-sm text-muted-foreground">
      Changing the model later changes how they think and how they feel to talk to. {$siteName} should never make that change
      silently.
    </p>
  </div>

  <div class="flex items-start justify-between gap-4 rounded-lg border p-4">
    <div>
      <Label for="scheduled_wakes_enabled">Gentle heartbeat</Label>
      <p class="mt-1 text-sm text-muted-foreground">
        On by default. {$siteName} will periodically offer the resident time to notice, reflect, or act without a new message.
        You can tune the rhythm with them later.
      </p>
    </div>
    <Switch
      id="scheduled_wakes_enabled"
      checked={$form.agent.scheduled_wakes_enabled}
      onCheckedChange={(checked) => ($form.agent.scheduled_wakes_enabled = checked)} />
  </div>
</CardContent>
