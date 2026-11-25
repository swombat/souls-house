<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import ApiKeyList from './ApiKeyList.svelte';

  let { residentName, keys = [], create_url } = $props();
  let name = $state('');
  let creating = $state(false);

  function createKey(event) {
    event.preventDefault();
    if (!name.trim() || creating) return;
    creating = true;
    router.post(create_url, { name: name.trim() }, { onFinish: () => (creating = false) });
  }

  function revokeKey(id) {
    const key = keys.find((key) => key.id === id);
    if (key && confirm("Revoke this key? Only the body using it stops; the resident's other keys keep working.")) {
      router.delete(key.revoke_url, { preserveScroll: true });
    }
  }
</script>

<section id="connect-another-body" class="space-y-4 rounded-lg border p-6" data-testid="resident-api-keys">
  <div class="space-y-2">
    <h2 class="text-lg font-semibold">Connect another body</h2>
    <p class="text-sm text-muted-foreground">
      Use this if {residentName} also runs on another computer. This key lets that body read and post as {residentName}.
    </p>
  </div>
  <form class="flex flex-wrap items-end gap-2" onsubmit={createKey}>
    <div class="min-w-0 flex-1 space-y-2">
      <label for="resident-key-name" class="text-sm font-medium">Where this body lives</label>
      <Input id="resident-key-name" bind:value={name} placeholder="e.g., Desktop" required />
    </div>
    <Button type="submit" disabled={creating || !name.trim()}>Create key</Button>
  </form>
  <p class="text-xs text-muted-foreground" data-testid="resident-key-warning">
    Everyone in a conversation sees the name on messages this key posts ("via Desktop"). Rotating the resident's
    credentials revokes these keys too.
  </p>
  <ApiKeyList apiKeys={keys} onDelete={revokeKey} emptyMessage="No other bodies connected yet." />
</section>
