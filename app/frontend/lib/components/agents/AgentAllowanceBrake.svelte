<script>
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';
  import { Switch } from '$lib/components/shadcn/switch';

  let { form, status = null, canManage = false } = $props();

  const statusLabels = {
    disabled: 'Off',
    available: 'Allowance permits scheduled work',
    braked: 'Scheduled work is braked',
    braked_stale: 'Braked using an earlier low reading until its known reset',
    unavailable: 'Fresh allowance unavailable; scheduled work is not braked',
  };
</script>

<section class="space-y-4" aria-labelledby="allowance-brake-heading">
  <div>
    <h2 id="allowance-brake-heading" class="text-lg font-semibold">Scheduled-work allowance brake</h2>
    <p class="text-sm text-muted-foreground">
      Skip scheduled model wakes below your chosen remaining allowance. Commitments stay owed; direct requests and
      owner-marked essential work are not braked.
    </p>
  </div>

  {#if canManage}
    <div class="rounded border bg-muted/30 p-4 space-y-3">
      <div class="flex items-center justify-between gap-6">
        <Label for="allowance_brake_enabled">Enable allowance brake</Label>
        <Switch
          id="allowance_brake_enabled"
          aria-label="Enable allowance brake"
          checked={$form.agent.allowance_brake_threshold_percent !== null}
          onCheckedChange={(checked) => ($form.agent.allowance_brake_threshold_percent = checked ? 40 : null)} />
      </div>
      {#if $form.agent.allowance_brake_threshold_percent !== null}
        <Label for="allowance_brake_threshold_percent">Brake below remaining allowance (%)</Label>
        <Input
          id="allowance_brake_threshold_percent"
          type="number"
          min={0}
          max={100}
          step={1}
          bind:value={$form.agent.allowance_brake_threshold_percent}
          class="max-w-32" />
      {/if}
      {#if $form.errors?.allowance_brake_threshold_percent}
        <p class="text-sm text-destructive">{$form.errors.allowance_brake_threshold_percent}</p>
      {/if}
      <div class="flex items-center justify-between gap-6">
        <div>
          <Label for="scheduled_wakes_essential">Heartbeats are essential</Label>
          <p class="text-xs text-muted-foreground">Exempt this resident's scheduled heartbeats from the brake.</p>
        </div>
        <Switch
          id="scheduled_wakes_essential"
          aria-label="Heartbeats are essential"
          checked={$form.agent.scheduled_wakes_essential}
          onCheckedChange={(checked) => ($form.agent.scheduled_wakes_essential = checked)} />
      </div>
    </div>
  {:else}
    <p class="text-sm text-muted-foreground">
      Only the owner or an account admin can change the brake or essential exemptions.
    </p>
  {/if}

  <p class="text-xs text-muted-foreground">
    This is a best-effort brake, not a spending cap. Missing or stale usage normally allows work to run; a known low
    reading still brakes until its provider-reported reset. OpenAI uses remaining percentages, never a weekly
    projection. Turning this off allows future work without replaying skipped rhythm ticks.
  </p>
  {#if status}
    <p class="text-sm" role="status">
      {statusLabels[status.status] || 'Allowance status unavailable'}
      {#if status.checked_at}<span class="text-muted-foreground"> · reading from {status.checked_at}</span>{/if}
    </p>
  {/if}
</section>
