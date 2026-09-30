<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '$lib/components/shadcn/card';
  let { report, filters } = $props();
  let fromValue = $state(toUtcInput(filters.from));
  let toValue = $state(toUtcInput(filters.to));
  let triggerKind = $state(filters.trigger_kind || '');
  let provider = $state(filters.provider || '');
  let model = $state(filters.model || '');
  let sessionOutcome = $state(filters.session_outcome || '');
  let sessionRollReason = $state(filters.session_roll_reason || '');

  function toUtcInput(value) {
    return value ? new Date(value).toISOString().slice(0, 16) : '';
  }

  function utcIso(value) {
    return value ? `${value}:00Z` : undefined;
  }

  export function reportParams(extra = {}) {
    return compact({
      from: utcIso(fromValue),
      to: utcIso(toValue),
      trigger_kind: triggerKind,
      provider,
      model,
      session_outcome: sessionOutcome,
      session_roll_reason: sessionRollReason,
      ...extra,
    });
  }

  function compact(values) {
    return Object.fromEntries(Object.entries(values).filter(([, value]) => value !== '' && value != null));
  }

  function applyFilters(event) {
    event.preventDefault();
    router.get(window.location.pathname, reportParams(), { preserveState: false, preserveScroll: true });
  }

  function clearFilters() {
    triggerKind = '';
    provider = '';
    model = '';
    sessionOutcome = '';
    sessionRollReason = '';
    router.get(window.location.pathname, { from: utcIso(fromValue), to: utcIso(toValue) });
  }
</script>

<Card>
  <CardHeader>
    <CardTitle>Report window and filters</CardTitle>
    <CardDescription>
      {report.window.from} through {report.window.to}. The reporting service only sums stored invocation fields; it
      never reconstructs historical runtime usage.
    </CardDescription>
  </CardHeader>
  <CardContent>
    <form class="grid gap-3 md:grid-cols-2 xl:grid-cols-4" onsubmit={applyFilters}>
      <label class="grid gap-1 text-xs text-muted-foreground">
        From (UTC)
        <input
          class="rounded border bg-background px-2 py-1.5 text-sm text-foreground"
          type="datetime-local"
          bind:value={fromValue} />
      </label>
      <label class="grid gap-1 text-xs text-muted-foreground">
        To (UTC)
        <input
          class="rounded border bg-background px-2 py-1.5 text-sm text-foreground"
          type="datetime-local"
          bind:value={toValue} />
      </label>
      <label class="grid gap-1 text-xs text-muted-foreground">
        Trigger kind
        <select class="rounded border bg-background px-2 py-1.5 text-sm text-foreground" bind:value={triggerKind}>
          <option value="">All</option>
          {#each report.filter_options.trigger_kind as value}<option {value}>{value}</option>{/each}
        </select>
      </label>
      <label class="grid gap-1 text-xs text-muted-foreground">
        Provider
        <select class="rounded border bg-background px-2 py-1.5 text-sm text-foreground" bind:value={provider}>
          <option value="">All</option>
          {#each report.filter_options.provider as value}<option {value}>{value}</option>{/each}
        </select>
      </label>
      <label class="grid gap-1 text-xs text-muted-foreground">
        Model
        <select class="rounded border bg-background px-2 py-1.5 text-sm text-foreground" bind:value={model}>
          <option value="">All</option>
          {#each report.filter_options.model as value}<option {value}>{value}</option>{/each}
        </select>
      </label>
      <label class="grid gap-1 text-xs text-muted-foreground">
        Session outcome
        <select class="rounded border bg-background px-2 py-1.5 text-sm text-foreground" bind:value={sessionOutcome}>
          <option value="">All</option>
          {#each report.filter_options.session_outcome as value}<option {value}>{value}</option>{/each}
        </select>
      </label>
      <label class="grid gap-1 text-xs text-muted-foreground">
        Roll reason
        <select class="rounded border bg-background px-2 py-1.5 text-sm text-foreground" bind:value={sessionRollReason}>
          <option value="">All</option>
          {#each report.filter_options.session_roll_reason as value}<option {value}>{value}</option>{/each}
        </select>
      </label>
      <div class="flex items-end gap-2">
        <Button type="submit" size="sm">Apply</Button>
        <Button type="button" size="sm" variant="outline" onclick={clearFilters}>Clear dimensions</Button>
      </div>
    </form>
  </CardContent>
</Card>
