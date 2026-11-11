<script>
  import { page } from '@inertiajs/svelte';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';

  // Where /companion and Settings → Computers send people for the Mac app.
  // Blank keeps every download control at "Mac download coming soon".
  let { form } = $props();
</script>

<Card>
  <CardHeader>
    <CardTitle>Companion download</CardTitle>
    <CardDescription>
      The Mac download offered on the companion page and on each account's Computers page. Leave it blank until a
      Developer ID–signed, notarised build has been opened on a clean Mac; until then every download button reads "Mac
      download coming soon". An unsigned build is never linked here.
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-2">
    <Label for="companion_mac_download_url">Mac download address (https)</Label>
    <Input
      id="companion_mac_download_url"
      type="url"
      bind:value={form.companion_mac_download_url}
      placeholder="Blank: coming soon" />
    {#if $page.props.errors?.companion_mac_download_url}
      <p class="text-sm text-destructive">{$page.props.errors.companion_mac_download_url.join(', ')}</p>
    {/if}
  </CardContent>
</Card>
