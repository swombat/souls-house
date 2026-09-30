<script>
  import { Button } from '$lib/components/shadcn/button';
  let { sandboxStatus, diagnosticsError, diagnosticsLoading, diagnosticsLoaded, loadHostingDiagnostics } = $props();
</script>

<div class="border rounded-lg p-6 space-y-3">
  <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
    <h2 class="text-xl font-semibold">Docker sandbox diagnostics</h2>
    <Button type="button" variant="outline" size="sm" onclick={loadHostingDiagnostics} disabled={diagnosticsLoading}>
      {diagnosticsLoading ? 'Loading...' : 'Refresh diagnostics'}
    </Button>
  </div>
  {#if diagnosticsError}
    <div class="rounded border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
      {diagnosticsError}
    </div>
  {:else if diagnosticsLoading && !diagnosticsLoaded}
    <p class="text-sm text-muted-foreground">Loading Docker and filesystem diagnostics…</p>
  {/if}
  <div class="grid gap-2 text-sm sm:grid-cols-2">
    <p>
      Docker daemon:
      <span class="font-medium"
        >{sandboxStatus.docker_available === null
          ? 'checking'
          : sandboxStatus.docker_available
            ? 'reachable'
            : 'not reachable'}</span>
    </p>
    {#if sandboxStatus.docker_version}
      <p>Docker version: <span class="font-mono">{sandboxStatus.docker_version}</span></p>
    {/if}
    {#if sandboxStatus.configured_helixkit_app_url}
      <p>
        Configured callback URL: <span class="font-mono">{sandboxStatus.configured_helixkit_app_url}</span>
      </p>
    {/if}
    {#if sandboxStatus.container_helixkit_app_url}
      <p>
        Container callback URL: <span class="font-mono">{sandboxStatus.container_helixkit_app_url}</span>
      </p>
    {/if}
    <p>
      Runtime image present: <span class="font-medium"
        >{sandboxStatus.image_present === null ? 'checking' : sandboxStatus.image_present ? 'yes' : 'no'}</span>
    </p>
    <p>
      Container exists: <span class="font-medium"
        >{sandboxStatus.container_exists === null ? 'checking' : sandboxStatus.container_exists ? 'yes' : 'no'}</span>
    </p>
    {#if sandboxStatus.container_exists}
      <p>
        Container image current:
        <span class="font-medium"
          >{sandboxStatus.container_image_current === null || sandboxStatus.container_image_current === undefined
            ? 'checking'
            : sandboxStatus.container_image_current
              ? 'yes'
              : 'no'}</span>
      </p>
      <p>
        Image stale:
        <span class={sandboxStatus.image_stale ? 'font-medium text-amber-700' : 'font-medium'}>
          {sandboxStatus.image_stale === null || sandboxStatus.image_stale === undefined
            ? 'checking'
            : sandboxStatus.image_stale
              ? 'yes'
              : 'no'}
        </span>
      </p>
    {/if}
    {#if sandboxStatus.container_state}
      <p>Container state: <span class="font-mono">{sandboxStatus.container_state}</span></p>
    {/if}
    {#if sandboxStatus.container_exit_code !== undefined && sandboxStatus.container_exit_code !== null}
      <p>Exit code: <span class="font-mono">{sandboxStatus.container_exit_code}</span></p>
    {/if}
    <p>
      Identity volume:
      <span class="font-medium"
        >{sandboxStatus.identity_volume_exists === null
          ? 'checking'
          : sandboxStatus.identity_volume_exists
            ? 'present'
            : 'missing'}</span>
    </p>
    <p>
      Chaos volume: <span class="font-medium"
        >{sandboxStatus.chaos_volume_exists === null
          ? 'checking'
          : sandboxStatus.chaos_volume_exists
            ? 'present'
            : 'missing'}</span>
    </p>
    <p>
      Repository volume:
      <span class="font-medium"
        >{sandboxStatus.repo_volume_exists === null
          ? 'checking'
          : sandboxStatus.repo_volume_exists
            ? 'present'
            : 'missing'}</span>
    </p>
    <p>
      Work volume:
      <span class="font-medium"
        >{sandboxStatus.work_volume_exists === null
          ? 'checking'
          : sandboxStatus.work_volume_exists
            ? 'present'
            : 'missing'}</span>
    </p>
    <p>
      Private state volume:
      <span class="font-medium"
        >{sandboxStatus.state_volume_exists === null
          ? 'checking'
          : sandboxStatus.state_volume_exists
            ? 'present'
            : 'missing'}</span>
    </p>
  </div>
  {#if sandboxStatus.docker_error}
    <div class="rounded border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
      <div class="font-medium">Docker error</div>
      <div class="mt-1 font-mono text-xs whitespace-pre-wrap">{sandboxStatus.docker_error}</div>
    </div>
  {/if}
  {#if sandboxStatus.configuration_error}
    <div class="rounded border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
      <div class="font-medium">Hosting configuration error</div>
      <div class="mt-1 font-mono text-xs whitespace-pre-wrap">{sandboxStatus.configuration_error}</div>
    </div>
  {/if}
  {#if sandboxStatus.container_exists && sandboxStatus.container_image_current === false}
    <div class="rounded border border-amber-300/40 bg-amber-50 p-3 text-sm text-amber-900">
      This container was created from an older runtime image. Restarting promotion will recreate the container while
      preserving its identity, session, repository, and work volumes.
    </div>
  {/if}
  {#if sandboxStatus.container_error}
    <div class="rounded border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
      <div class="font-medium">Container error</div>
      <div class="mt-1 font-mono text-xs whitespace-pre-wrap">{sandboxStatus.container_error}</div>
    </div>
  {/if}
  {#if sandboxStatus.log_tail}
    <details class="rounded border bg-muted p-3 text-sm">
      <summary class="cursor-pointer font-medium">Container log tail</summary>
      <pre class="mt-2 overflow-x-auto whitespace-pre-wrap text-xs">{sandboxStatus.log_tail}</pre>
    </details>
  {/if}
</div>
