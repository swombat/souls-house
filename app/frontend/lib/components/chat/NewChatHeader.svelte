<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { List } from 'phosphor-svelte';
  import ChatTitleEditor from './ChatTitleEditor.svelte';

  let { onMenuOpen, title = $bindable(''), actions = null } = $props();
</script>

<header class="border-b border-border bg-muted/30 px-4 md:px-6 py-3 md:py-4">
  <div class="flex items-center gap-3">
    <Button variant="ghost" size="sm" onclick={onMenuOpen} class="h-8 w-8 p-0 md:hidden">
      <List size={20} />
    </Button>
    <ChatTitleEditor
      chat={{ title }}
      onDraftTitle={(value) => (title = value)}
      onCancelTitle={(value) => (title = value)}
      onSaveTitle={(value) => (title = value)} />
    {#if actions}
      <div class="ml-auto shrink-0">{@render actions()}</div>
    {/if}
  </div>
</header>
