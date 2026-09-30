<script>
  import { Card, CardContent, CardHeader, CardDescription } from '$lib/components/shadcn/card';
  import { number, aggregateNumber } from '$lib/runtime-report-formatting';
  let { report } = $props();
  const tokenLabels = {
    uncached_input_tokens: 'Ordinary input',
    cache_creation_input_tokens: 'Cache writes',
    cache_read_input_tokens: 'Cache reads',
    output_tokens: 'Output',
    reasoning_output_tokens: 'Reasoning output',
  };
</script>

<div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
  <Card>
    <CardHeader class="pb-2"><CardDescription>Interactions</CardDescription></CardHeader>
    <CardContent>
      <div class="text-2xl font-semibold">{number(report.summary.interactions)}</div>
      {#if report.summary.busy_retries > 0}
        <div class="mt-1 text-xs font-normal text-muted-foreground">
          {number(report.summary.busy_retries)} busy retries excluded
        </div>
      {/if}
    </CardContent>
  </Card>
  <Card>
    <CardHeader class="pb-2"><CardDescription>Logical sessions</CardDescription></CardHeader>
    <CardContent class="text-2xl font-semibold">{number(report.summary.logical_sessions)}</CardContent>
  </Card>
  <Card>
    <CardHeader class="pb-2"><CardDescription>Chaos processes</CardDescription></CardHeader>
    <CardContent class="text-2xl font-semibold">{number(report.summary.chaos_processes)}</CardContent>
  </Card>
  <Card>
    <CardHeader class="pb-2"><CardDescription>Provider requests</CardDescription></CardHeader>
    <CardContent class="text-xl font-semibold">
      {aggregateNumber(report.summary.provider_requests, report.summary.provider_request_unknown_rows)}
    </CardContent>
  </Card>
  <Card>
    <CardHeader class="pb-2"><CardDescription>Detailed telemetry</CardDescription></CardHeader>
    <CardContent class="text-sm">
      <div>{report.summary.complete_usage_rows} complete</div>
      <div class="text-amber-700 dark:text-amber-400">
        {report.summary.incomplete_usage_rows} incomplete · {report.summary.unavailable_usage_rows} unavailable
      </div>
      {#if report.summary.unsupported_usage_rows > 0}
        <div class="text-red-700 dark:text-red-400">{report.summary.unsupported_usage_rows} unsupported</div>
      {/if}
    </CardContent>
  </Card>
</div>

<div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
  {#each Object.entries(tokenLabels) as [key, label]}
    <Card>
      <CardHeader class="pb-2"><CardDescription>{label}</CardDescription></CardHeader>
      <CardContent class="text-lg font-semibold">
        {aggregateNumber(report.summary.tokens[key], report.summary.token_unknown_rows[key])}
      </CardContent>
    </Card>
  {/each}
</div>
