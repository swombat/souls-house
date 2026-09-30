<script>
  import { ArrowLeft } from 'phosphor-svelte';

  let { backHref, agentName } = $props();
</script>

<div class="mb-8">
  <a href={backHref} class="inline-flex items-center text-sm text-muted-foreground hover:text-foreground mb-4">
    <ArrowLeft class="mr-1 size-4" />
    Back to Residents
  </a>
  <h1 class="text-3xl font-bold">Edit Resident</h1>
  <p class="text-muted-foreground mt-1">Update {agentName}'s configuration</p>
</div>
