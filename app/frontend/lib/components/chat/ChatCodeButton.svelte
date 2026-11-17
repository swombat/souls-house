<script>
  import { Copy, Check } from 'phosphor-svelte';
  import { copyText } from '$lib/clipboard';

  // The conversation's code (the last part of its address), shown under the
  // title when the account has show_chat_codes on. A click or tap copies it.
  let { code } = $props();

  let copied = $state(false);
  let timer;

  async function copy() {
    if (!(await copyText(code))) return;
    copied = true;
    clearTimeout(timer);
    timer = setTimeout(() => (copied = false), 1500);
  }
</script>

<button
  type="button"
  onclick={copy}
  data-testid="chat-code-button"
  title={copied ? 'Copied' : 'Copy this conversation’s code'}
  aria-label={copied ? `Copied ${code}` : `Copy conversation code ${code}`}
  class="inline-flex items-center gap-1 rounded border border-border px-1.5 py-0.5 font-mono text-xs text-muted-foreground hover:bg-muted hover:text-foreground">
  {code}
  {#if copied}
    <Check size={12} weight="bold" />
  {:else}
    <Copy size={12} />
  {/if}
</button>
