<script>
  import FileAttachment from './FileAttachment.svelte';
  import { downloadAll } from '$lib/download-all.js';

  let { files = [], onImageClick = null, class: className = '' } = $props();

  const downloadable = $derived(files.filter((file) => file.url));
</script>

<div class="space-y-2 {className}">
  {#each files as file}
    <FileAttachment {file} {onImageClick} />
  {/each}
  {#if downloadable.length > 1}
    <button
      type="button"
      data-testid="download-all-files"
      onclick={() => downloadAll(downloadable)}
      class="text-xs text-muted-foreground hover:text-foreground hover:underline">
      Download all ({downloadable.length})
    </button>
  {/if}
</div>
