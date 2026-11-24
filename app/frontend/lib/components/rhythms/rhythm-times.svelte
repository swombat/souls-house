<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { fieldErrors, timeRowErrors } from '$lib/rhythms';

  let { times = $bindable(), daily = false, errors = {} } = $props();
</script>

<div class="space-y-2">
  {#each times as time, index}
    {@const rowErrors = [...timeRowErrors(times, index), ...fieldErrors(errors, `times_of_day.${index}`)]}
    <div class="space-y-1">
      <Label for={`rhythm_time_${index}`} class="text-xs font-normal text-muted-foreground">
        {daily ? `Time ${index + 1}` : 'At'}
      </Label>
      <div class="flex items-center gap-2">
        <Input
          id={`rhythm_time_${index}`}
          type="time"
          bind:value={() => times[index], (value) => (times = times.map((time, row) => (row === index ? value : time)))}
          aria-invalid={rowErrors.length > 0}
          aria-describedby={`rhythm_time_errors_${index}`} />
        {#if daily && times.length > 1}
          <Button
            type="button"
            variant="outline"
            aria-label={`Remove time ${index + 1}`}
            onclick={() => (times = times.filter((_, row) => row !== index))}>Remove</Button>
        {/if}
      </div>
      <div id={`rhythm_time_errors_${index}`}>
        {#each rowErrors as error}
          <p class="text-sm text-destructive">{error}</p>
        {/each}
      </div>
    </div>
  {/each}
  {#if daily}
    <Button type="button" variant="outline" disabled={times.length >= 12} onclick={() => (times = [...times, ''])}>
      Add time
    </Button>
    <p class="text-xs text-muted-foreground">Up to 12 times a day. Times are saved in chronological order.</p>
    {#if times.length > 1}
      <p class="text-xs text-muted-foreground">
        Changing to another repeat schedule keeps only the earliest time and drops the others when saved.
      </p>
    {/if}
  {/if}
</div>
