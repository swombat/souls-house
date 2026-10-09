<script>
  import { router } from '@inertiajs/svelte';
  import {
    ShieldWarning,
    Buildings,
    Gear,
    ClockClockwise,
    Play,
    Megaphone,
    Pulse,
    RocketLaunch,
    ListBullets,
    ChartLine,
  } from 'phosphor-svelte';
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import { buttonVariants } from '$lib/components/shadcn/button/index.js';
  import { cn } from '$lib/utils.js';
  import { adminNoticesPath } from '@/routes';
  import { deployLines } from './deployInfo.js';

  let deployInfo = $state(null);
  let deployInfoFailed = $state(false);
  let loading = false;

  // Fetched when the menu opens, so an ordinary page load never waits on GitHub.
  async function loadDeployInfo() {
    if (loading) return;
    loading = true;
    try {
      const response = await fetch('/admin/deploy_info', { headers: { Accept: 'application/json' } });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      deployInfo = await response.json();
      deployInfoFailed = false;
    } catch {
      deployInfoFailed = true;
    } finally {
      loading = false;
    }
  }

  const lines = $derived(deployLines(deployInfo, { failed: deployInfoFailed }));
  const workflows = $derived(deployInfo?.workflows || []);

  // Starts the deploy; the server redirects to the Deploys page, which then
  // follows the new run.
  function deploy(workflow) {
    if (!confirm(`Run "${workflow.name}" on master now?`)) return;
    router.post('/admin/deploys', { workflow: workflow.key });
  }
</script>

<DropdownMenu.Root onOpenChange={(open) => open && loadDeployInfo()}>
  <DropdownMenu.Trigger class={cn(buttonVariants({ variant: 'outline' }), 'rounded-full px-2.5 gap-1')}>
    <ShieldWarning class="text-red-500" />
    <span class="text-xs font-normal text-muted-foreground text-red-500 hidden md:inline"> Site Admin </span>
  </DropdownMenu.Trigger>
  <DropdownMenu.Content align="end">
    <DropdownMenu.Item onclick={() => router.visit('/admin/dashboard')}>
      <ChartLine class="mr-2 size-4" />
      <span>Dashboard</span>
    </DropdownMenu.Item>
    <DropdownMenu.Item onclick={() => router.visit('/admin/settings')}>
      <Gear class="mr-2 size-4" />
      <span>Site Settings</span>
    </DropdownMenu.Item>
    <DropdownMenu.Item onclick={() => router.visit('/admin/accounts')}>
      <Buildings class="mr-2 size-4" />
      <span>Manage Accounts</span>
    </DropdownMenu.Item>
    <DropdownMenu.Item onclick={() => router.visit('/admin/audit_logs')}>
      <ClockClockwise class="mr-2 size-4" />
      <span>Audit Logs</span>
    </DropdownMenu.Item>
    <DropdownMenu.Item onclick={() => router.visit('/admin/runtime_sessions')}>
      <Pulse class="mr-2 size-4" />
      <span>Resident Sessions</span>
    </DropdownMenu.Item>
    <DropdownMenu.Item onclick={() => router.visit('/admin/resident_turns')}>
      <Pulse class="mr-2 size-4" />
      <span>Resident Concurrency</span>
    </DropdownMenu.Item>
    <DropdownMenu.Item onclick={() => router.visit('/admin/jobs')}>
      <Play class="mr-2 size-4" />
      <span>Background Jobs</span>
    </DropdownMenu.Item>
    <DropdownMenu.Item onclick={() => router.visit(adminNoticesPath())}>
      <Megaphone class="mr-2 size-4" />
      <span>Site Notices</span>
    </DropdownMenu.Item>
    <DropdownMenu.Sub>
      <DropdownMenu.SubTrigger data-testid="deploy-submenu">
        <RocketLaunch class="mr-2 size-4" />
        <span>Deploy</span>
      </DropdownMenu.SubTrigger>
      <DropdownMenu.SubContent>
        <DropdownMenu.Item onclick={() => router.visit('/admin/deploys')}>
          <ListBullets class="mr-2 size-4" />
          <span>Deployments</span>
        </DropdownMenu.Item>
        <DropdownMenu.Separator />
        {#each workflows as workflow (workflow.key)}
          <DropdownMenu.Item onclick={() => deploy(workflow)} title={workflow.description}>
            <RocketLaunch class="mr-2 size-4" />
            <span>{workflow.name}</span>
          </DropdownMenu.Item>
        {:else}
          <div class="px-2 py-1.5 text-xs text-muted-foreground">
            {deployInfoFailed ? 'Couldn’t load deploys' : 'Loading…'}
          </div>
        {/each}
      </DropdownMenu.SubContent>
    </DropdownMenu.Sub>
    <DropdownMenu.Separator />
    <div class="px-2 py-1.5 text-xs text-muted-foreground max-w-72 space-y-0.5" data-testid="deploy-info">
      {#each lines as line}
        <div class="truncate" title={line.title || line.text}>{line.text}</div>
      {/each}
    </div>
  </DropdownMenu.Content>
</DropdownMenu.Root>
