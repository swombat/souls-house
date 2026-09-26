<script>
  import { File, FileImage, FileAudio, FileVideo, FilePdf, FileDoc } from 'phosphor-svelte';

  let { file, onImageClick = null } = $props();

  const isImage = !!file.thumb_url;

  function getIcon(contentType) {
    if (!contentType) return File;

    if (contentType.startsWith('image/')) return FileImage;
    if (contentType.startsWith('audio/')) return FileAudio;
    if (contentType.startsWith('video/')) return FileVideo;
    if (contentType.includes('pdf')) return FilePdf;
    if (contentType.includes('word') || contentType.includes('document')) return FileDoc;

    return File;
  }

  function formatFileSize(bytes) {
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  }

  function handleImageClick(e) {
    if (isImage && onImageClick) {
      e.preventDefault();
      onImageClick(file);
    }
  }

  const IconComponent = getIcon(file.content_type);
</script>

{#if isImage}
  <button
    type="button"
    onclick={handleImageClick}
    class="block rounded-lg overflow-hidden border border-border hover:border-primary/50 transition-colors cursor-pointer max-w-xs">
    <img src={file.thumb_url || file.url} alt={file.filename} class="max-w-full max-h-48 object-cover" />
    <div class="px-2 py-1 bg-muted/50 text-xs text-muted-foreground flex items-center justify-between gap-2">
      <span class="truncate">{file.filename}</span>
      <span class="flex-shrink-0">{formatFileSize(file.byte_size)}</span>
    </div>
  </button>
{:else}
  <a
    href={file.url}
    download={file.filename}
    class="flex items-center gap-2 p-2 rounded-md border border-border bg-muted/50 hover:bg-muted transition-colors max-w-xs group">
    <svelte:component this={IconComponent} size={20} class="text-muted-foreground flex-shrink-0" />
    <div class="flex-1 min-w-0">
      <div class="text-sm font-medium truncate group-hover:text-primary transition-colors">
        {file.filename}
      </div>
      <div class="text-xs text-muted-foreground">
        {formatFileSize(file.byte_size)}
      </div>
    </div>
  </a>
{/if}
