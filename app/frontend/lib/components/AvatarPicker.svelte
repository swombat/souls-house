<script>
  // Set a picture four ways: pick a file, drop one (or an image dragged from another tab),
  // paste a screenshot, or paste its web address (the house fetches it). Each one saves at
  // once; the server answers errors under `avatar`.
  import { onMount } from 'svelte';
  import { router } from '@inertiajs/svelte';
  import { UploadSimple, LinkSimple } from 'phosphor-svelte';
  import Button from '$lib/components/shadcn/button/button.svelte';
  import Input from '$lib/components/shadcn/input/input.svelte';
  import {
    avatarFileError,
    imageFileFrom,
    isTextEntry,
    transferHasAvatar,
    webAddress,
    webAddressFrom,
  } from '$lib/avatar-input';

  let {
    uploadPath,
    deletePath = null,
    currentUrl = null,
    removeLabel = 'Remove picture',
    pasteAnywhere = true,
    onDone = () => {},
    children,
  } = $props();

  let fileInput;
  let busy = $state(false);
  let error = $state(null);
  let address = $state('');
  let dragDepth = $state(0);

  function send(data, { file = false } = {}) {
    busy = true;
    error = null;
    router.patch(uploadPath, data, {
      forceFormData: file,
      preserveScroll: true,
      // Keep whatever the surrounding form has unsaved.
      preserveState: true,
      onSuccess: (page) => {
        const failed = page?.props?.errors?.avatar;
        if (failed) {
          error = failed;
          return;
        }
        address = '';
        onDone();
      },
      onError: (errors) => {
        error = errors.avatar || 'That didn’t work. Please try again.';
      },
      onFinish: () => {
        busy = false;
        if (fileInput) fileInput.value = '';
      },
    });
  }

  function useFile(file) {
    const problem = avatarFileError(file);
    if (problem) {
      error = problem;
      return;
    }
    const data = new FormData();
    data.append('avatar', file);
    send(data, { file: true });
  }

  function useAddress(text) {
    const url = webAddress(text);
    if (!url) {
      error = 'Paste a web address starting with http:// or https://';
      return;
    }
    send({ url });
  }

  function remove() {
    if (!deletePath) return;
    busy = true;
    error = null;
    router.delete(deletePath, {
      preserveScroll: true,
      preserveState: true,
      onSuccess: () => onDone(),
      onError: () => (error = 'Couldn’t remove the picture. Please try again.'),
      onFinish: () => (busy = false),
    });
  }

  function dragEnter(event) {
    if (!transferHasAvatar(event.dataTransfer)) return;
    event.preventDefault();
    dragDepth += 1;
  }

  function dragOver(event) {
    if (!transferHasAvatar(event.dataTransfer)) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = busy ? 'none' : 'copy';
  }

  function dragLeave(event) {
    if (!transferHasAvatar(event.dataTransfer)) return;
    dragDepth = Math.max(0, dragDepth - 1);
  }

  function drop(event) {
    if (!transferHasAvatar(event.dataTransfer)) return;
    event.preventDefault();
    dragDepth = 0;
    if (busy) return;
    const transfer = event.dataTransfer;
    if (Array.from(transfer.types || []).includes('Files')) {
      useFile(imageFileFrom(transfer));
    } else {
      const url = webAddressFrom(transfer);
      if (url) useAddress(url);
      else error = 'Drop a picture, or an image from another page';
    }
  }

  function handlePaste(event) {
    if (busy) return;
    const transfer = event.clipboardData;
    const file = Array.from(transfer?.items || []).some((item) => item.kind === 'file')
      ? imageFileFrom(transfer)
      : null;
    if (file) {
      event.preventDefault();
      useFile(file);
      return;
    }
    const url = webAddress(transfer?.getData('text/plain'));
    if (url && !isTextEntry(event.target)) {
      event.preventDefault();
      useAddress(url);
    }
  }

  // Pasting a link into the address box fetches it straight away.
  function addressPaste(event) {
    event.stopPropagation();
    const url = webAddress(event.clipboardData?.getData('text/plain'));
    if (!url || busy) return;
    event.preventDefault();
    address = url;
    useAddress(url);
  }

  onMount(() => {
    if (!pasteAnywhere) return;
    window.addEventListener('paste', handlePaste);
    return () => window.removeEventListener('paste', handlePaste);
  });
</script>

<div class="space-y-3" data-avatar-picker>
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="flex flex-col items-center gap-3 rounded-lg border-2 border-dashed p-4 text-center transition-colors {dragDepth >
    0
      ? 'border-primary bg-primary/5'
      : 'border-muted-foreground/25'}"
    data-avatar-dropzone
    data-dragging={dragDepth > 0 ? '' : undefined}
    ondragenter={dragEnter}
    ondragover={dragOver}
    ondragleave={dragLeave}
    ondrop={drop}>
    {@render children?.()}
    <p class="text-sm text-muted-foreground">
      {busy ? 'Saving…' : 'Drop a picture here, paste one, or'}
    </p>
    <Button type="button" variant="outline" size="sm" disabled={busy} onclick={() => fileInput?.click()}>
      <UploadSimple class="size-4" /> Choose a file
    </Button>
    <input
      bind:this={fileInput}
      type="file"
      accept="image/png,image/jpeg,image/gif,image/webp"
      class="hidden"
      data-avatar-file
      onchange={(event) => useFile(event.currentTarget.files?.[0])} />
  </div>

  <!-- Not a <form>: the picker sits inside the settings and resident forms, and Enter here
       must fetch the picture, not submit the page. -->
  <div class="flex gap-2">
    <Input
      type="url"
      placeholder="…or paste a picture’s web address"
      aria-label="Picture web address"
      bind:value={address}
      disabled={busy}
      onpaste={addressPaste}
      onkeydown={(event) => {
        if (event.key !== 'Enter') return;
        event.preventDefault();
        if (!busy && address.trim()) useAddress(address);
      }}
      data-avatar-url />
    <Button
      type="button"
      variant="secondary"
      disabled={busy || !address.trim()}
      onclick={() => useAddress(address)}
      data-avatar-fetch>
      <LinkSimple class="size-4" /> Fetch
    </Button>
  </div>

  <p class="text-xs text-muted-foreground">PNG, JPEG, GIF or WebP, up to 5 MB.</p>

  {#if error}
    <div class="bg-destructive/15 text-destructive px-3 py-2 rounded-md text-sm" role="alert">{error}</div>
  {/if}

  {#if deletePath && currentUrl}
    <Button type="button" variant="ghost" size="sm" class="text-destructive" disabled={busy} onclick={remove}>
      {removeLabel}
    </Button>
  {/if}
</div>
