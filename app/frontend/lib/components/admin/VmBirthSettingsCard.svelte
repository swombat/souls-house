<script>
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Switch } from '$lib/components/shadcn/switch';

  let { form, status = {} } = $props();
</script>

<Card>
  <CardHeader>
    <CardTitle>Residents on their own server</CardTitle>
    <CardDescription>
      When this is on, every new resident is created on its own Hetzner Cloud server instead of on this house. A
      resident that can't go on a server is refused with the reason. It is never created here instead. Existing
      residents stay where they are. Leave it off to run everything on one server.
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-4">
    <label class="flex items-center gap-3">
      <Switch
        aria-label="New residents on their own server"
        checked={!!form.new_residents_on_vm}
        onCheckedChange={(on) => (form.new_residents_on_vm = on)} />
      <span class="font-medium">New residents on their own server</span>
    </label>

    <div class="space-y-2">
      <label for="vm_resident_limit" class="font-medium">Most resident servers at once</label>
      <input
        id="vm_resident_limit"
        class="block h-10 w-28 rounded-md border bg-background px-3"
        type="number"
        min="0"
        max="1000"
        step="1"
        required
        bind:value={form.vm_resident_limit} />
      <p class="text-sm text-muted-foreground">
        Every server that might exist counts, including one whose purchase or deletion hasn't been confirmed. At the
        limit, new residents are refused. {status.vm_count ?? 0} counted now.
      </p>
    </div>

    <div class="text-sm text-muted-foreground space-y-1" data-testid="vm-birth-exclusions">
      <p class="font-medium text-foreground">Not yet possible on a server, so refused while this is on:</p>
      <ul class="list-disc pl-5">
        <li>imported residents (archive or GitHub)</li>
        <li>a subscription login for the resident's model (API keys and on-the-house models are fine)</li>
      </ul>
    </div>

    {#if status.enabled && status.birth_refusal}
      <p class="text-sm rounded-md border border-amber-500/50 bg-amber-500/10 p-3" data-testid="vm-birth-status">
        New residents are being refused: {status.birth_refusal}
      </p>
    {:else if !status.procurement_configured}
      <p class="text-sm text-muted-foreground" data-testid="vm-birth-status">Server ordering isn't configured.</p>
    {/if}
  </CardContent>
</Card>
