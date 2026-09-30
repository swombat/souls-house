<script>
  import { activityMaximum, activityHeight } from '$lib/activity-chart';

  let { groups, label, class: className = 'h-32', barClass = '', minimumHeight = 0, footer } = $props();
  const maximum = $derived(activityMaximum(groups));
</script>

<div class={`flex items-stretch gap-1 ${className}`} role="img" aria-label={label}>
  {#each groups as group (group.key)}
    <div class="flex min-w-0 flex-1 flex-col gap-2">
      <div class="flex min-h-0 flex-1 items-end gap-px">
        {#each group.bars as bar, index (index)}
          <div class={`flex h-full min-w-0 flex-1 flex-col justify-end ${barClass}`} title={bar.title}>
            {#each bar.segments as segment, segmentIndex (segmentIndex)}
              <div class={segment.colour} style:height={`${activityHeight(segment.value, maximum, minimumHeight)}%`}>
              </div>
            {/each}
          </div>
        {/each}
      </div>
      {#if footer}{@render footer(group)}{/if}
    </div>
  {/each}
</div>
