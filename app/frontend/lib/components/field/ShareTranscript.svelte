<script>
  // The transcript's Share menu: copy it as text, or make a link that anyone
  // can open without an account (FieldRecordingShare). A link's URL is shown
  // once, when it's made; live links are listed after that by when they
  // expire, each with Revoke.
  import { router } from '@inertiajs/svelte';
  import * as Popover from '$lib/components/shadcn/popover/index.js';
  import { Button, buttonVariants } from '$lib/components/shadcn/button/index.js';
  import { Check, Copy, LinkSimple, ShareNetwork } from 'phosphor-svelte';
  import { copyText } from '$lib/clipboard';
  import { DEFAULT_SHARE_EXPIRY, SHARE_EXPIRIES, expiryLine } from '$lib/transcript-share';

  let { text = '', sharesUrl, shares = [] } = $props();

  let open = $state(false);
  let expiry = $state(DEFAULT_SHARE_EXPIRY);
  let creating = $state(false);
  let error = $state(null);
  let created = $state(null); // { url, expires_at, copied }
  let copiedTranscript = $state(false);
  let copiedLink = $state(false);

  async function copyTranscript() {
    copiedTranscript = await copyText(text);
    if (copiedTranscript) setTimeout(() => (copiedTranscript = false), 2000);
  }

  async function createLink() {
    creating = true;
    error = null;
    created = null;
    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content');
      const response = await fetch(sharesUrl, {
        method: 'POST',
        headers: { 'X-CSRF-Token': csrfToken || '', Accept: 'application/json', 'Content-Type': 'application/json' },
        body: JSON.stringify({ expiry }),
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        error = body.error || "The link couldn't be made. Please try again.";
        return;
      }
      created = { url: body.share.url, expires_at: body.share.expires_at };
      copiedLink = await copyText(created.url);
      router.reload({ only: ['shares'] });
    } catch {
      error = "The link couldn't be made. Please try again.";
    } finally {
      creating = false;
    }
  }

  async function copyCreated() {
    if (!created) return;
    copiedLink = await copyText(created.url);
  }

  function revoke(share) {
    if (!confirm('Revoke this link? Anyone who has it will no longer be able to read the transcript.')) return;
    router.delete(`${sharesUrl}/${share.id}`, { preserveScroll: true, preserveState: true, only: ['shares', 'flash'] });
  }

  function openChanged(value) {
    if (!value) {
      created = null;
      error = null;
      copiedLink = false;
    }
  }
</script>

<Popover.Root bind:open onOpenChange={openChanged}>
  <Popover.Trigger class={buttonVariants({ variant: 'outline', size: 'sm' })} data-testid="share-transcript">
    <ShareNetwork class="size-4" /> Share
  </Popover.Trigger>
  <Popover.Content class="w-80 space-y-4" align="end" data-testid="share-transcript-menu">
    <Button
      variant="ghost"
      size="sm"
      class="w-full justify-start"
      onclick={copyTranscript}
      data-testid="copy-transcript">
      {#if copiedTranscript}
        <Check class="size-4" /> Copied
      {:else}
        <Copy class="size-4" /> Copy transcript to clipboard
      {/if}
    </Button>

    <div class="space-y-2 border-t pt-3">
      <p class="text-sm font-medium">Share a link</p>
      <p class="text-xs text-muted-foreground">
        Anyone with the link can read the transcript, without signing in. They don't see the audio, notes or anything
        else in this Field.
      </p>
      <fieldset class="space-y-1">
        <legend class="text-xs text-muted-foreground">Link stops working after</legend>
        <div class="flex flex-wrap gap-1" role="radiogroup">
          {#each SHARE_EXPIRIES as option (option.value)}
            <button
              type="button"
              role="radio"
              aria-checked={expiry === option.value}
              class="rounded-md border px-2 py-1 text-xs {expiry === option.value
                ? 'border-primary bg-primary text-primary-foreground'
                : 'hover:bg-muted'}"
              onclick={() => (expiry = option.value)}
              data-testid="share-expiry-{option.value}">
              {option.label}
            </button>
          {/each}
        </div>
      </fieldset>
      <Button size="sm" class="w-full" onclick={createLink} disabled={creating} data-testid="create-share-link">
        <LinkSimple class="size-4" />
        {creating ? 'Making link…' : 'Create link'}
      </Button>
      {#if error}
        <p class="text-xs text-destructive" data-testid="share-error">{error}</p>
      {/if}
      {#if created}
        <div class="space-y-1" data-testid="share-created">
          <div class="flex gap-1">
            <input
              readonly
              value={created.url}
              class="min-w-0 flex-1 rounded-md border bg-muted px-2 py-1 text-xs"
              onfocus={(event) => event.currentTarget.select()}
              data-testid="share-url" />
            <Button variant="outline" size="sm" onclick={copyCreated} aria-label="Copy link">
              {#if copiedLink}<Check class="size-4" />{:else}<Copy class="size-4" />{/if}
            </Button>
          </div>
          <p class="text-xs text-muted-foreground">
            {copiedLink ? 'Copied. ' : ''}{expiryLine(created.expires_at)}. This is the only time the link is shown.
          </p>
        </div>
      {/if}
    </div>

    {#if shares.length}
      <div class="space-y-2 border-t pt-3" data-testid="share-list">
        <p class="text-sm font-medium">Live links</p>
        <ul class="space-y-2">
          {#each shares as share (share.id)}
            <li class="flex items-start justify-between gap-2 text-xs">
              <div class="min-w-0">
                <p>{expiryLine(share.expires_at)}</p>
                <p class="text-muted-foreground">
                  {share.created_by_name ? `By ${share.created_by_name} · ` : ''}{share.view_count === 1
                    ? 'Opened once'
                    : share.view_count
                      ? `Opened ${share.view_count} times`
                      : 'Not opened yet'}
                </p>
              </div>
              <button
                type="button"
                class="shrink-0 text-muted-foreground hover:text-destructive"
                onclick={() => revoke(share)}
                data-testid="revoke-share">
                Revoke
              </button>
            </li>
          {/each}
        </ul>
      </div>
    {/if}
  </Popover.Content>
</Popover.Root>
