<script>
  let { orientationResult, testResult } = $props();
</script>

{#if orientationResult}
  <div class="rounded border bg-muted p-3 text-sm">
    <div>Orientation: <span class="font-mono">{orientationResult.status}</span></div>
    {#if orientationResult.error}<div class="text-destructive">{orientationResult.error}</div>{/if}
    {#if orientationResult.runtime_stderr}
      <details class="mt-2">
        <summary class="cursor-pointer font-medium text-destructive">Runtime stderr</summary>
        <pre class="mt-1 overflow-x-auto whitespace-pre-wrap text-xs">{orientationResult.runtime_stderr}</pre>
      </details>
    {/if}
    {#if orientationResult.runtime_stdout}
      <details class="mt-2">
        <summary class="cursor-pointer font-medium">Runtime stdout</summary>
        <pre class="mt-1 overflow-x-auto whitespace-pre-wrap text-xs">{orientationResult.runtime_stdout}</pre>
      </details>
    {/if}
  </div>
{/if}

{#if testResult}
  <div class="rounded border bg-muted p-3 text-sm">
    <div>Status: <span class="font-mono">{testResult.status}</span></div>
    {#if testResult.transport_status}<div>Transport: {testResult.transport_status}</div>{/if}
    {#if testResult.runtime_status}<div>Runtime: {testResult.runtime_status}</div>{/if}
    {#if testResult.error}<div class="text-destructive">{testResult.error}</div>{/if}
    {#if testResult.runtime_stderr}
      <details class="mt-2">
        <summary class="cursor-pointer font-medium text-destructive">Runtime stderr</summary>
        <pre class="mt-1 overflow-x-auto whitespace-pre-wrap text-xs">{testResult.runtime_stderr}</pre>
      </details>
    {/if}
    {#if testResult.runtime_stdout}
      <details class="mt-2">
        <summary class="cursor-pointer font-medium">Runtime stdout</summary>
        <pre class="mt-1 overflow-x-auto whitespace-pre-wrap text-xs">{testResult.runtime_stdout}</pre>
      </details>
    {/if}
  </div>
{/if}
