<script>
  import { page } from '@inertiajs/svelte';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';

  // Where /companion and Settings → Computers send people for the Mac app.
  // Blank keeps every download control at "Mac download coming soon".
  let { form } = $props();

  const linux = [
    { key: 'amd64', label: 'Linux x86-64' },
    { key: 'arm64', label: 'Linux ARM64' },
  ];
</script>

<Card>
  <CardHeader>
    <CardTitle>Companion download</CardTitle>
    <CardDescription>
      The downloads offered on the companion page and on each account's Computers page. Leave the Mac address blank
      until a Developer ID–signed, notarised build has been opened on a clean Mac; until then every download button
      reads "Mac download coming soon". An unsigned build is never linked here.
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
    <div class="space-y-2 border-t pt-4">
      <p class="text-sm text-muted-foreground">
        Early build (unsigned, not notarised). Offered under the main button as "Download it early", with a notice of
        what macOS will do and the checksum beside it. Set both or neither; leave blank to offer nothing early.
      </p>
      <Label for="companion_mac_early_download_url">Early download address (https)</Label>
      <Input
        id="companion_mac_early_download_url"
        type="url"
        bind:value={form.companion_mac_early_download_url}
        placeholder="Blank: no early download" />
      {#if $page.props.errors?.companion_mac_early_download_url}
        <p class="text-sm text-destructive">{$page.props.errors.companion_mac_early_download_url.join(', ')}</p>
      {/if}
      <Label for="companion_mac_early_download_sha256">Its sha256</Label>
      <Input
        id="companion_mac_early_download_sha256"
        class="font-mono"
        bind:value={form.companion_mac_early_download_sha256}
        placeholder="64 hex characters" />
      {#if $page.props.errors?.companion_mac_early_download_sha256}
        <p class="text-sm text-destructive">{$page.props.errors.companion_mac_early_download_sha256.join(', ')}</p>
      {/if}
    </div>
    <div class="space-y-2 border-t pt-4">
      <p class="text-sm text-muted-foreground">
        Linux (no signing step). Shown beside the Mac download on every computer, each with its checksum. Set the
        address and sha256 of a release tarball together, or leave both blank to hide that one.
      </p>
      {#each linux as item (item.key)}
        <Label for="companion_linux_{item.key}_download_url">{item.label} address (https)</Label>
        <Input
          id="companion_linux_{item.key}_download_url"
          type="url"
          bind:value={form[`companion_linux_${item.key}_download_url`]}
          placeholder="Blank: not offered" />
        {#if $page.props.errors?.[`companion_linux_${item.key}_download_url`]}
          <p class="text-sm text-destructive">
            {$page.props.errors[`companion_linux_${item.key}_download_url`].join(', ')}
          </p>
        {/if}
        <Label for="companion_linux_{item.key}_download_sha256">Its sha256</Label>
        <Input
          id="companion_linux_{item.key}_download_sha256"
          class="font-mono"
          bind:value={form[`companion_linux_${item.key}_download_sha256`]}
          placeholder="64 hex characters" />
        {#if $page.props.errors?.[`companion_linux_${item.key}_download_sha256`]}
          <p class="text-sm text-destructive">
            {$page.props.errors[`companion_linux_${item.key}_download_sha256`].join(', ')}
          </p>
        {/if}
      {/each}
    </div>
  </CardContent>
</Card>
