<script>
  import { router } from '@inertiajs/svelte';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { Switch } from '$lib/components/shadcn/switch/index.js';

  let { account } = $props();

  function setXHouseApp(enabled) {
    router.patch(`/admin/accounts/${account.id}/x_posting_house_app`, {
      account: { x_posting_house_app: enabled },
    });
  }
</script>

<Card class="mb-8">
  <CardHeader>
    <CardTitle>X posting</CardTitle>
    <CardDescription>
      Accounts with a site admin among their members post to X through the house X app. Turn this on to let this account
      use it too. Turning it off disconnects a handle connected through the house app.
    </CardDescription>
  </CardHeader>
  <CardContent>
    <div class="flex items-center justify-between gap-6 rounded-md border p-4">
      <div class="space-y-1">
        <Label for={`x-posting-house-app-${account.id}`}>Use the house X app</Label>
        <p class="text-sm text-muted-foreground">
          {#if account.x_posting_site_admin_member}
            A site admin is a member, so this account uses the house app either way.
          {:else if account.x_posting_own_app}
            This account has its own X app, which it uses first.
          {:else}
            This account has no X app of its own.
          {/if}
        </p>
      </div>
      <Switch
        id={`x-posting-house-app-${account.id}`}
        aria-label="Use the house X app"
        checked={account.x_posting_house_app}
        onCheckedChange={setXHouseApp} />
    </div>
  </CardContent>
</Card>
