<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';

  let { connection, account } = $props();
  let name = $state('');
  let editing = $state(false);
  let saving = $state(false);
  let error = $state('');
  function reset() {
    editing = false;
    error = '';
  }
  function save(event) {
    event.preventDefault();
    saving = true;
    error = '';
    router.patch(
      `/accounts/${account.id}/service_connections/${connection.id}`,
      {
        service_connection: { label: name.trim() },
      },
      {
        preserveScroll: true,
        onSuccess: () => {
          editing = false;
        },
        onError: (errors) => {
          error = Object.values(errors).flat().join(' ') || 'Could not save connection name.';
        },
        onFinish: () => {
          saving = false;
        },
      }
    );
  }
</script>

<form class="space-y-2" onsubmit={save}>
  <label class="block text-sm font-medium" for={`connection-${connection.id}-name`}>Connection name</label>
  <input
    id={`connection-${connection.id}-name`}
    class="w-full rounded-md border bg-background px-3 py-2 text-sm"
    value={editing ? name : connection.custom_label || ''}
    maxlength="100"
    disabled={saving}
    aria-invalid={error ? 'true' : undefined}
    aria-describedby={`connection-${connection.id}-name-hint`}
    oninput={(event) => {
      name = event.currentTarget.value;
      editing = true;
      error = '';
    }} />
  <p id={`connection-${connection.id}-name-hint`} class="text-xs text-muted-foreground">
    Leave blank to use the automatic name.
  </p>
  {#if error}<p role="alert" class="text-sm text-destructive">{error}</p>{/if}
  <div class="flex gap-2">
    <Button type="submit" size="sm" disabled={!editing || saving}>{saving ? 'Saving…' : 'Save'}</Button>
    <Button type="button" variant="outline" size="sm" disabled={!editing || saving} onclick={reset}>Cancel</Button>
  </div>
</form>
