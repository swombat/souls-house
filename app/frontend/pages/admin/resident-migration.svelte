<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';

  let { resident, report, measured = false, flash = {} } = $props();
  let moving = $state(false);
  let confirming = $state(false);

  const path = $derived(`/admin/agents/${resident.id}/migration`);
  const mb = (bytes) => `${(bytes / 1048576).toFixed(1)} MB`;
  const blocked = $derived(report.gates.filter((gate) => !gate.ok));

  function measure() {
    router.get(path, { measure: '1' }, { preserveScroll: true });
  }

  function move() {
    moving = true;
    router.post(path, {}, { onFinish: () => ((moving = false), (confirming = false)) });
  }
</script>

<svelte:head><title>Move {resident.name} to its own server</title></svelte:head>

<div class="mx-auto max-w-3xl space-y-6 p-6">
  <div>
    <a href="/admin/residents" class="text-sm text-muted-foreground hover:text-foreground">← All residents</a>
    <h1 class="mt-2 text-2xl font-semibold">Move {resident.name} to its own server</h1>
    <p class="text-sm text-muted-foreground">
      {resident.account_name} · A dry run first: nothing here changes until “Move it now”.
    </p>
  </div>

  {#if flash?.notice}
    <div class="rounded-md bg-green-50 p-3 text-sm text-green-700 dark:bg-green-950 dark:text-green-300">
      {flash.notice}
    </div>
  {/if}
  {#if flash?.alert}
    <div
      class="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300"
      data-testid="migration-alert">
      {flash.alert}
    </div>
  {/if}

  <section class="space-y-2">
    <h2 class="font-medium">Gates</h2>
    <ul class="divide-y rounded-md border text-sm" data-testid="migration-gates">
      {#each report.gates as gate}
        <li class="flex gap-3 p-3" data-ok={gate.ok}>
          <span class={gate.ok ? 'text-green-600' : 'text-red-600'}>{gate.ok ? 'Yes' : 'No'}</span>
          <span class="flex-1">
            <span class="font-medium">{gate.name}</span>
            {#if gate.refusal}<span class="block text-muted-foreground">{gate.refusal}</span>{/if}
          </span>
        </li>
      {/each}
    </ul>
  </section>

  <section class="space-y-2">
    <div class="flex items-center justify-between">
      <h2 class="font-medium">Sizes against the seed limits</h2>
      <Button variant="outline" size="sm" onclick={measure}>{measured ? 'Measure again' : 'Measure sizes'}</Button>
    </div>
    <p class="text-xs text-muted-foreground">
      Limits per role: {mb(report.limits.compressed_bytes)} compressed, {mb(report.limits.unpacked_bytes)} unpacked,
      {report.limits.entries.toLocaleString()} entries. Measured read-only from its volumes; on a running resident the real
      copy, taken stopped, can differ.
    </p>
    {#if report.measure_error}
      <p class="text-sm text-red-600" data-testid="migration-measure-error">
        Could not measure: {report.measure_error}
      </p>
    {/if}
    {#if report.roles.length}
      <table class="w-full text-sm" data-testid="migration-roles">
        <thead class="text-left text-muted-foreground">
          <tr><th class="py-1">Role</th><th>Compressed</th><th>Unpacked</th><th>Entries</th><th>Fits</th></tr>
        </thead>
        <tbody class="tabular-nums">
          {#each report.roles as role}
            <tr class="border-t" data-fits={role.fits}>
              <td class="py-1 font-medium">{role.role}</td>
              <td>{mb(role.compressed_bytes)}</td>
              <td>{mb(role.unpacked_bytes)}</td>
              <td>{role.entries.toLocaleString()}</td>
              <td class={role.fits ? 'text-green-600' : 'text-red-600'}>{role.fits ? 'Yes' : role.refusal}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    {:else if !report.measure_error}
      <p class="text-sm text-muted-foreground">Not measured yet.</p>
    {/if}
  </section>

  <section class="space-y-2">
    <h2 class="font-medium">Stated, not switched</h2>
    <ul class="list-disc space-y-1 pl-5 text-sm text-muted-foreground">
      {#each report.facts as fact}<li>{fact}</li>{/each}
    </ul>
  </section>

  <section class="space-y-2 border-t pt-4">
    <p class="text-sm text-muted-foreground">
      Moving stages a copy of its home and admits it under the same checks as a new resident server. It stays off the
      house and gets no turn before its server's first verified backup.
      {#if blocked.length}It will refuse now: {blocked[0].refusal}{/if}
    </p>
    {#if confirming}
      <div class="flex gap-2">
        <Button variant="destructive" size="sm" disabled={moving} onclick={move} data-testid="migration-confirm"
          >{moving ? 'Moving…' : `Move ${resident.name} now`}</Button>
        <Button variant="outline" size="sm" onclick={() => (confirming = false)}>Cancel</Button>
      </div>
    {:else}
      <Button size="sm" onclick={() => (confirming = true)} data-testid="migration-move">Move it now…</Button>
    {/if}
  </section>
</div>
