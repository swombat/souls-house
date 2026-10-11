<script>
  import { page, router } from '@inertiajs/svelte';
  import { MagnifyingGlass, ChatText, ArrowRight } from 'phosphor-svelte';
  import PaginationNav from '$lib/components/navigation/PaginationNav.svelte';
  import { accountChatPath, searchAccountChatsPath } from '@/routes';

  let { query = '', results = [], pagination = {} } = $props();

  const account = $derived($page.props.account);

  let searchInput = $state(query);

  function handleSearch(event) {
    event?.preventDefault();
    if (!searchInput.trim()) return;

    router.get(
      searchAccountChatsPath(account.id),
      { q: searchInput.trim() },
      {
        preserveState: false,
      }
    );
  }

  function goToChat(chatId) {
    router.visit(accountChatPath(account.id, chatId));
  }

  function handlePageChange(newPage) {
    router.get(searchAccountChatsPath(account.id), { q: query, page: newPage }, { preserveState: false });
  }

  function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }

  function highlightMatch(text, term) {
    if (!term || !text) return escapeHtml(text || '');
    const escaped = escapeHtml(text);
    const termEscaped = escapeHtml(term).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const regex = new RegExp(`(${termEscaped})`, 'gi');
    return escaped.replace(regex, '<mark class="bg-yellow-200 dark:bg-yellow-800 rounded px-0.5">$1</mark>');
  }
</script>

<svelte:head>
  <title>{query ? `Search: ${query}` : 'Search'}</title>
</svelte:head>

<div class="max-w-3xl mx-auto px-4 md:px-6 py-8">
  <h1 class="text-2xl font-semibold mb-6">Search Messages</h1>

  <form onsubmit={handleSearch} class="mb-8">
    <div class="relative">
      <MagnifyingGlass size={20} class="absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground" />
      <input
        type="text"
        bind:value={searchInput}
        placeholder="Search across all messages..."
        class="w-full pl-10 pr-4 py-2.5 border border-input rounded-lg bg-background
               text-sm focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent" />
    </div>
  </form>

  {#if query}
    {#if results.length === 0}
      <div class="text-center py-12 text-muted-foreground">
        <MagnifyingGlass size={48} class="mx-auto mb-4 opacity-30" />
        <p class="text-lg">No results found for "{query}"</p>
        <p class="text-sm mt-1">Try a different search term</p>
      </div>
    {:else}
      <p class="text-sm text-muted-foreground mb-4">
        {pagination.count}
        {pagination.count === 1 ? 'result' : 'results'} for "{query}"
      </p>

      <div class="space-y-3">
        {#each results as result (result.id)}
          <button
            onclick={() => goToChat(result.chat_id)}
            class="w-full text-left p-4 border border-border rounded-lg bg-card
                   hover:bg-muted/50 transition-colors group cursor-pointer">
            <div class="flex items-center justify-between mb-2">
              <div class="flex items-center gap-2 text-sm font-medium text-foreground">
                <ChatText size={16} class="text-muted-foreground" />
                <span class="truncate">{result.chat_title}</span>
                {#if result.room_name}
                  <span class="shrink-0 rounded bg-muted px-1.5 text-xs text-muted-foreground">{result.room_name}</span>
                {/if}
              </div>
              <ArrowRight
                size={14}
                class="text-muted-foreground opacity-0 group-hover:opacity-100 transition-opacity" />
            </div>
            <div class="text-sm text-muted-foreground whitespace-pre-line leading-relaxed line-clamp-4">
              {@html highlightMatch(result.snippet, query)}
            </div>
            <div class="mt-2 text-xs text-muted-foreground/60">
              {result.author_name} &middot; {result.created_at}
            </div>
          </button>
        {/each}
      </div>

      <PaginationNav {pagination} onPageChange={handlePageChange} class="mt-6" />
    {/if}
  {:else}
    <div class="text-center py-12 text-muted-foreground">
      <MagnifyingGlass size={48} class="mx-auto mb-4 opacity-30" />
      <p>Enter a search term to find messages across all your conversations</p>
    </div>
  {/if}
</div>
