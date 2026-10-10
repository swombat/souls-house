<script>
  import { alarmBanner } from './deployAlarm.js';

  let { alarm = null } = $props();

  const banner = $derived(alarmBanner(alarm));
</script>

{#if banner}
  <div
    role={banner.tone === 'alert' ? 'alert' : 'status'}
    data-testid="deploy-alarm-banner"
    data-tone={banner.tone}
    class={banner.tone === 'alert'
      ? 'border-b border-rose-300 bg-rose-50 px-4 py-2 text-sm text-rose-900 dark:border-rose-900 dark:bg-rose-950 dark:text-rose-100'
      : 'border-b bg-muted px-4 py-2 text-sm text-muted-foreground'}>
    <span>{banner.text}</span>
    <a class="ml-2 underline" href={alarm.deploys_path || '/admin/deploys'}>Deploys</a>
    {#if alarm.last_run_url}
      <a class="ml-2 underline" href={alarm.last_run_url} target="_blank" rel="noopener">Last run</a>
    {/if}
    {#if alarm.runbook_url}
      <a class="ml-2 underline" href={alarm.runbook_url} target="_blank" rel="noopener">Recovery runbook</a>
    {/if}
  </div>
{/if}
