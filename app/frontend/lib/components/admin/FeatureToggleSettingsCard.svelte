<script>
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Label } from '$lib/components/shadcn/label';
  import { Switch } from '$lib/components/shadcn/switch';

  let { form } = $props();

  const toggles = [
    {
      id: 'allow_signups',
      label: 'Allow New User Signups',
      description: 'When disabled, signup page returns 403',
    },
    {
      id: 'allow_chats',
      label: 'Allow Chats',
      description: 'When disabled, chat pages return 403',
    },
    {
      id: 'allow_agents',
      label: 'Allow Residents',
      description: 'When disabled, resident management is hidden',
    },
    {
      id: 'show_usage_in_chat',
      label: 'Show usage in chat',
      description: 'Show weekly subscription usage beside resident names. Usage below 25% is always shown.',
    },
  ];
</script>

<Card>
  <CardHeader>
    <CardTitle>Feature Toggles</CardTitle>
    <CardDescription>Control which features are available</CardDescription>
  </CardHeader>
  <CardContent class="space-y-6">
    {#each toggles as toggle}
      <div class="flex items-center justify-between">
        <div class="space-y-1">
          <Label for={toggle.id}>{toggle.label}</Label>
          <p class="text-sm text-muted-foreground">{toggle.description}</p>
        </div>
        <Switch id={toggle.id} checked={form[toggle.id]} onCheckedChange={(checked) => (form[toggle.id] = checked)} />
      </div>
    {/each}
  </CardContent>
</Card>
