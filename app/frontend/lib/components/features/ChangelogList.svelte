<script>
  let { entries } = $props();

  const groups = $derived.by(() => {
    const byDate = [];
    for (const entry of entries) {
      const last = byDate.at(-1);
      if (last?.date === entry.date) last.entries.push(entry);
      else byDate.push({ date: entry.date, entries: [entry] });
    }
    return byDate;
  });

  function formatDate(iso) {
    return new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-GB', {
      day: 'numeric',
      month: 'long',
      year: 'numeric',
      timeZone: 'UTC',
    });
  }
</script>

<ol class="space-y-8" data-testid="changelog">
  {#each groups as group (group.date)}
    <li class="grid gap-3 sm:grid-cols-[10rem_1fr] sm:gap-6">
      <time datetime={group.date} class="text-sm font-medium text-muted-foreground sm:pt-0.5">
        {formatDate(group.date)}
      </time>
      <ul class="space-y-4">
        {#each group.entries as entry (entry.title)}
          <li data-testid="changelog-entry">
            <p class="font-medium">{entry.title}</p>
            <p class="mt-1 text-sm leading-relaxed text-muted-foreground">{entry.body}</p>
          </li>
        {/each}
      </ul>
    </li>
  {/each}
</ol>
