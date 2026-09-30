<script>
  import RuntimeReportFilters from '$lib/components/admin/runtime-report-filters.svelte';
  import RuntimeReportSummary from '$lib/components/admin/runtime-report-summary.svelte';
  import RuntimeSessionDetails from '$lib/components/admin/runtime-session-details.svelte';
  import { aggregateBytes } from '$lib/runtime-report-formatting';

  import { router } from '@inertiajs/svelte';
  import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '$lib/components/shadcn/card';

  import { siteName } from '$lib/branding';

  let { agent, report, filters, selected_session_id = null } = $props();
  let filterPanel;

  function selectSession(sessionId) {
    router.get(window.location.pathname, filterPanel.reportParams({ session_id: sessionId }), {
      preserveState: true,
      preserveScroll: true,
    });
  }
</script>

<svelte:head>
  <title>{agent.name} runtime usage</title>
</svelte:head>

<div class="container mx-auto max-w-[1800px] space-y-6 px-4 py-8">
  <div>
    <p class="text-sm text-muted-foreground">{agent.account_name} · {agent.runtime}</p>
    <h1 class="text-2xl font-bold">{agent.name} runtime usage</h1>
    <p class="mt-1 text-sm text-muted-foreground">
      Invocation-local usage grouped by {$siteName} logical session. The window and every timestamp below are UTC.
    </p>
  </div>

  <RuntimeReportFilters bind:this={filterPanel} {report} {filters} />
  <RuntimeReportSummary {report} />
  <Card>
    <CardHeader>
      <CardTitle>Session breakdown</CardTitle>
      <CardDescription>
        {report.summary.fresh} fresh · {report.summary.resumed} resumed · {report.summary.rolled} rolled ·
        {report.summary.fallbacks} fallbacks. Selected prompts:
        {aggregateBytes(report.summary.selected_prompt_bytes, report.summary.selected_prompt_unknown_rows)}.
      </CardDescription>
    </CardHeader>
    <CardContent class="space-y-3">
      {#if report.sessions.length === 0}
        <p class="text-sm text-muted-foreground">
          No runtime interactions were recorded in this UTC window and filter set.
        </p>
      {/if}

      {#each report.sessions as session}
        <RuntimeSessionDetails {session} selected={selected_session_id === session.session_id} {selectSession} />
      {/each}
    </CardContent>
  </Card>
</div>
