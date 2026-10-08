<script>
  import HouseAllowance from '$lib/components/agents/house-allowance.svelte';
  import HouseModelChoice from '$lib/components/agents/house-model-choice.svelte';
  import { CardHeader, CardTitle, CardDescription, CardContent } from '$lib/components/shadcn/card';
  import { siteName } from '$lib/branding';

  import { Label } from '$lib/components/shadcn/label';
  import { Switch } from '$lib/components/shadcn/switch';
  import AgentModelSelect from '$lib/components/agents/AgentModelSelect.svelte';
  let { form, grouped_models, houseOffered = false, selectedModel = $bindable() } = $props();
  let houseModels = $derived(grouped_models['On the house'] || []);
</script>

<CardHeader>
  <CardTitle>Runtime and rhythm</CardTitle>
  <CardDescription
    >Choose the substrate that wakes and whether {$siteName} offers regular unprompted time.</CardDescription>
</CardHeader>
<CardContent class="space-y-6">
  {#if houseOffered && houseModels.length > 0}
    <HouseModelChoice models={houseModels} bind:value={selectedModel} />
  {/if}

  <div class="space-y-2">
    <Label>{houseOffered ? 'Or any model' : 'Model'}</Label>
    <AgentModelSelect groupedModels={grouped_models} bind:value={selectedModel} triggerClass="w-full" />
    <p class="text-sm text-muted-foreground">
      Changing the model later changes how they think and how they feel to talk to. {$siteName} should never make that change
      silently.
    </p>
  </div>

  <HouseAllowance {selectedModel} />

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
