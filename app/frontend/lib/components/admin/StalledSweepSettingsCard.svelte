<script>
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';

  let { form } = $props();

  const intervals = [
    { value: 0, label: 'Off' },
    { value: 10, label: '10 min' },
    { value: 30, label: '30 min' },
    { value: 60, label: '60 min' },
  ];
</script>

<Card>
  <CardHeader>
    <CardTitle>Stalled threads</CardTitle>
    <CardDescription>
      Judges rooms that have gone quiet: whose move is it, and is it a resident's? Shadow mode only records the verdict
      (<a class="underline" href="/admin/stalled_sweeps">see the log</a>); it posts nothing and wakes nobody.
    </CardDescription>
  </CardHeader>
  <CardContent>
    <div role="radiogroup" aria-label="Stalled-thread sweep interval" class="inline-flex gap-1 rounded-md border p-1">
      {#each intervals as interval}
        <button
          type="button"
          role="radio"
          aria-checked={Number(form.stalled_sweep_minutes ?? 0) === interval.value}
          class="rounded px-3 py-1.5 text-sm transition-colors {Number(form.stalled_sweep_minutes ?? 0) === interval.value
            ? 'bg-primary text-primary-foreground'
            : 'text-muted-foreground hover:bg-muted'}"
          onclick={() => (form.stalled_sweep_minutes = interval.value)}>
          {interval.label}
        </button>
      {/each}
    </div>
  </CardContent>
</Card>
