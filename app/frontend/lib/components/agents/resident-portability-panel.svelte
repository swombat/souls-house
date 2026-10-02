<script>
  import { onDestroy } from 'svelte';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import ResidentPortabilityWarning from './resident-portability-warning.svelte';

  let { portability } = $props();
  let stopConfirmed = $state(false);
  let startConfirmed = $state(false);
  let pending = $state(null);
  let error = $state('');
  let controller;

  onDestroy(() => controller?.abort());

  async function changeRuntime(action) {
    const stopping = action === 'stop';
    const url = stopping ? portability?.stop_url : portability?.activate_url;
    if (!portability?.can_manage || !url || pending || !(stopping ? stopConfirmed : startConfirmed)) return;

    pending = action;
    error = '';
    controller = new AbortController();
    try {
      const response = await fetch(url, {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          Accept: 'application/json',
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        },
        body: JSON.stringify({ confirmed: true }),
        signal: controller.signal,
      });
      const data = response.status === 204 ? {} : await response.json();
      if (!response.ok) {
        error =
          typeof data.error === 'string'
            ? data.error
            : 'The request was refused. Check the resident status before trying again.';
        // A busy stop still pauses/disables new work while the current turn drains.
        if (stopping) router.reload({ only: ['portability', 'agent'] });
        return;
      }
      stopConfirmed = false;
      startConfirmed = false;
      if (data.redirect_url) router.visit(data.redirect_url);
      else router.reload({ only: ['portability', 'agent'] });
    } catch (failure) {
      if (failure.name !== 'AbortError') {
        error = 'Could not confirm the result. Refresh the resident status before trying again.';
      }
    } finally {
      pending = null;
    }
  }
</script>

<section class="space-y-5">
  <div>
    <h2 class="text-xl font-semibold">Export / Import</h2>
    <p class="text-sm text-muted-foreground">
      Account owners can transfer a resident's private files and supported memory.
    </p>
  </div>
  <ResidentPortabilityWarning />
  {#if portability?.can_manage}
    <div class="space-y-2">
      <h3 class="font-medium">Export this resident</h3>
      {#if portability.export_ready && portability.export_url}
        <a class="text-primary underline" href={portability.export_url}>Download resident archive</a>
      {:else}
        <p class="text-sm" role="status">
          {portability.unavailable_reason || 'Stop the resident before exporting.'}
        </p>
      {/if}
      <p class="text-sm text-muted-foreground">
        Export requires a stopped resident. Imported profiles using an external graph may not be supported.
      </p>
      {#if portability.stop_url}
        <div class="space-y-3 pt-2">
          <p class="text-sm">
            Stop for export pauses and disables the resident. Background processes stop only when no active, unknown or
            pending turn remains. If a turn is busy, the server refuses to stop processes and leaves the resident paused
            and inactive to drain; it does not kill the turn.
          </p>
          <label class="flex items-start gap-2 text-sm">
            <input class="mt-1" type="checkbox" bind:checked={stopConfirmed} disabled={!!pending} />
            <span>I understand stopping interrupts background services and prevents new resident work.</span>
          </label>
          <Button
            type="button"
            variant="outline"
            disabled={!!pending || !stopConfirmed}
            onclick={() => changeRuntime('stop')}>
            {pending === 'stop' ? 'Stopping…' : 'Stop for export'}
          </Button>
        </div>
      {/if}
    </div>
    {#if portability.activate_url}
      <div class="space-y-3">
        <h3 class="font-medium">{portability.imported ? 'Start restored resident' : 'Resume resident'}</h3>
        {#if portability.imported}
          <p class="text-sm">
            First start executes archived code. Review the archive and trust its contents before starting. Reconnect
            required services first. Scheduled wakes stay disabled.
          </p>
          <label class="flex items-start gap-2 text-sm">
            <input class="mt-1" type="checkbox" bind:checked={startConfirmed} disabled={!!pending} />
            <span>I have reviewed and trust the archived code and reconnected the services this resident needs.</span>
          </label>
        {:else}
          <p class="text-sm">
            Resume enables the resident and their background processes again. Existing schedule preferences are
            preserved.
          </p>
          <label class="flex items-start gap-2 text-sm">
            <input class="mt-1" type="checkbox" bind:checked={startConfirmed} disabled={!!pending} />
            <span>I confirm this resident may resume work and background services.</span>
          </label>
        {/if}
        <Button type="button" disabled={!!pending || !startConfirmed} onclick={() => changeRuntime('activate')}>
          {pending === 'activate' ? 'Starting…' : portability.imported ? 'Start restored resident' : 'Resume resident'}
        </Button>
      </div>
    {/if}
    {#if error}
      <p role="alert" class="text-sm text-destructive">{error}</p>
    {/if}
    {#if portability.import_url}
      <a class="text-primary underline" href={portability.import_url}>Import a resident archive</a>
    {/if}
  {:else}
    <p class="text-sm">Only account owners can export or import resident archives.</p>
  {/if}
</section>
