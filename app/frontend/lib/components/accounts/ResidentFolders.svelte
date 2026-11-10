<script>
  import { HardDrives } from 'phosphor-svelte';
  import { ACCESS_LABEL, ACCESS_RANK, folderRows, offered, volumeLabel } from '$lib/companion-volumes.js';

  // One resident's folders on one computer. With a report from the computer,
  // an owner picks off, read or write per folder, never above what it allows;
  // without one, the folders are only listed. The page decides what a choice
  // does (write asks first); this only says which folder and what was picked.
  let { device, resident, can_manage = false, busy = false, redraw = 0, onchoose } = $props();

  function choose(row, event) {
    const access = event.currentTarget.value;
    if (access !== row.current) onchoose(row, access);
  }
</script>

{#if can_manage && device.ceiling}
  {@const rows = folderRows(device, resident)}
  {#if rows.length === 0}
    <p class="mt-1 pl-7 text-sm text-muted-foreground">
      None. {device.name} doesn't allow this resident any folders.
    </p>
  {:else}
    <ul class="mt-2 space-y-1.5 pl-7">
      {#each rows as row (row.volume)}
        {@const label = volumeLabel(row.volume)}
        <li class="flex items-center gap-2 text-sm" title={row.volume} data-testid="computer-folder">
          <HardDrives size={16} class="shrink-0 text-muted-foreground" />
          <label for="folder-{device.id}-{resident.id}-{row.volume}" class="min-w-0 flex-1 truncate">
            {label.name}
            {#if label.id}<span class="font-mono text-xs text-muted-foreground">{label.id}</span>{/if}
          </label>
          {#key `${row.current}-${redraw}`}
            <select
              id="folder-{device.id}-{resident.id}-{row.volume}"
              class="shrink-0 rounded-md border border-input bg-background px-2 py-1 text-sm"
              value={row.current}
              disabled={busy}
              onchange={(event) => choose(row, event)}>
              {#each ['off', 'read', 'write'] as access}
                <option value={access} disabled={!offered(row, access)}>{ACCESS_LABEL[access]}</option>
              {/each}
            </select>
          {/key}
        </li>
        {#if ACCESS_RANK[row.current] > ACCESS_RANK[row.ceiling]}
          <li class="pl-6 text-xs text-muted-foreground">
            {device.name} no longer lists this much access. You can lower it or turn it off here.
          </li>
        {/if}
      {/each}
    </ul>
  {/if}
  <p class="mt-2 pl-7 text-xs text-muted-foreground">
    What {device.name} allows, as it reported {new Date(device.ceiling.reported_at).toLocaleString()}{device.ceiling
      .current
      ? ''
      : ' on an earlier connection; it may have changed since'}. To allow more, change it on the computer itself.
  </p>
{:else}
  {#if resident.volumes.length === 0}
    <p class="mt-1 pl-7 text-sm text-muted-foreground">None</p>
  {:else}
    <ul class="mt-2 space-y-1.5 pl-7">
      {#each resident.volumes as volume (volume.volume)}
        {@const label = volumeLabel(volume.volume)}
        <li class="flex items-center gap-2 text-sm" title={volume.volume}>
          <HardDrives size={16} class="shrink-0 text-muted-foreground" />
          <span class="min-w-0 truncate">
            {label.name}
            {#if label.id}<span class="font-mono text-xs text-muted-foreground">{label.id}</span>{/if}
          </span>
          <span
            class={`ml-auto shrink-0 rounded-full px-2 py-0.5 text-xs font-medium ${
              volume.access === 'write'
                ? 'bg-amber-100 text-amber-900 dark:bg-amber-950 dark:text-amber-200'
                : 'bg-muted text-muted-foreground'
            }`}>
            {volume.access === 'write' ? 'Read and write' : 'Read only'}
          </span>
        </li>
      {/each}
    </ul>
  {/if}
  {#if can_manage}
    <p class="mt-2 pl-7 text-xs text-muted-foreground">
      {device.name} hasn't said which folders it allows yet. Once its companion app is updated and connected, you can change
      folders here.
    </p>
  {/if}
{/if}
