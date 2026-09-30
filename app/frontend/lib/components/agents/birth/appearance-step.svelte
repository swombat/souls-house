<script>
  import { CardHeader, CardTitle, CardDescription, CardContent } from '$lib/components/shadcn/card';
  import { siteName } from '$lib/branding';

  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';
  import AgentAppearanceFields from '$lib/components/agents/AgentAppearanceFields.svelte';
  import { agentIconFor } from '$lib/agent-icons';
  let { form, colour_options, icon_options } = $props();
  let IconComponent = $derived(agentIconFor($form.agent.icon));
</script>

<CardHeader>
  <CardTitle>Appearance</CardTitle>
  <CardDescription>Choose how {$siteName} will display this resident. These details remain editable.</CardDescription>
</CardHeader>
<CardContent class="space-y-6">
  <div class="flex items-center gap-4 rounded-lg border p-4">
    <div
      class="rounded-xl p-3 {$form.agent.colour
        ? `bg-${$form.agent.colour}-100 dark:bg-${$form.agent.colour}-900`
        : 'bg-primary/10'}">
      <IconComponent
        class="size-7 {$form.agent.colour
          ? `text-${$form.agent.colour}-700 dark:text-${$form.agent.colour}-300`
          : 'text-primary'}"
        weight="duotone" />
    </div>
    <div>
      <p class="font-semibold">{$form.agent.name || 'Display name'}</p>
      <p class="text-sm text-muted-foreground">{$siteName} interface preview</p>
    </div>
  </div>

  <div class="space-y-2">
    <Label for="name">Display name</Label>
    <Input id="name" bind:value={$form.agent.name} maxlength={100} placeholder="How {$siteName} should label them" />
    <p class="text-sm text-muted-foreground">
      This label does not require the resident to use or identify with this name.
    </p>
    {#if $form.errors.name}<p class="text-sm text-destructive">{$form.errors.name}</p>{/if}
  </div>

  <AgentAppearanceFields
    bind:colour={$form.agent.colour}
    bind:icon={$form.agent.icon}
    colourOptions={colour_options}
    iconOptions={icon_options}
    colourLabel="Display colour"
    iconLabel="Display icon" />
</CardContent>
