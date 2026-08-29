<script>
  let { service, selection = {}, onchange = () => {}, disabled = false } = $props();

  function groupValue(group) {
    return selection[group.key] || group.default;
  }

  function optionRank(group, key) {
    return group.options.find((option) => option.key === key)?.rank ?? 0;
  }

  function parentFloor(group) {
    if (!group.parent) return 0;
    const parent = service.authority_groups.find((candidate) => candidate.key === group.parent);
    return parent ? optionRank(parent, groupValue(parent)) : 0;
  }

  function update(group, value) {
    const next = { ...selection, [group.key]: value };
    if (!group.parent) {
      const floor = optionRank(group, value);
      for (const child of service.authority_groups.filter((candidate) => candidate.parent === group.key)) {
        if (optionRank(child, next[child.key] || child.default) < floor) {
          const raised = child.options.find((option) => option.rank === floor);
          next[child.key] = raised?.key || next[child.key] || child.default;
        }
      }
    }
    onchange(next);
  }
</script>

<div class="space-y-2 rounded-md border bg-muted/20 p-3">
  {#each service.authority_groups as group}
    <label class={`flex items-center justify-between gap-4 text-sm ${group.parent ? 'pl-5' : ''}`}>
      <span>
        {group.parent ? '↳ ' : ''}{group.name}
      </span>
      <select
        class="min-w-44 rounded-md border bg-background px-3 py-1.5 text-sm"
        value={groupValue(group)}
        {disabled}
        onchange={(event) => update(group, event.currentTarget.value)}>
        {#each group.options as option}
          <option value={option.key} disabled={option.rank < parentFloor(group)}>{option.name}</option>
        {/each}
      </select>
    </label>
  {/each}
  <p class="text-xs text-muted-foreground">
    Drive access sets the minimum effective access for Docs, Sheets, and Slides.
  </p>
</div>
