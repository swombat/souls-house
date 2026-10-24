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

<!-- Every chats/* page renders inside the fixed chat viewport, which hides
     overflow, so this page has to be its own scroll container. -->
<div class="min-h-0 flex-1 overflow-y-auto overscroll-contain" data-testid="search-scroll">
  <div class="max-w-3xl mx-auto px-4 md:px-6 py-6 md:py-8">
    <h1 class="text-2xl font-semibold mb-6">Search Messages</h1>

    <form onsubmit={handleSearch} class="mb-6 md:mb-8">
      <div class="relative">
        <MagnifyingGlass size={20} class="absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground" />
        <input
          type="search"
          enterkeyhint="search"
          bind:value={searchInput}
          placeholder="Search across all messages..."
          class="w-full pl-10 pr-4 py-2.5 border border-input rounded-lg bg-background
               text-base md:text-sm focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent" />
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

        <div class="space-y-3" data-testid="search-results">
          {#each results as result (result.id)}
            <button
              onclick={() => goToChat(result.chat_id)}
              class="block w-full min-w-0 overflow-hidden text-left p-3 md:p-4 border border-border rounded-lg bg-card
                   hover:bg-muted/50 transition-colors group cursor-pointer">
              <div class="flex min-w-0 items-center justify-between gap-2 mb-2">
                <div class="flex min-w-0 items-center gap-2 text-sm font-medium text-foreground">
                  <ChatText size={16} class="shrink-0 text-muted-foreground" />
                  <span class="min-w-0 truncate">{result.chat_title}</span>
                  {#if result.room_name}
                    <span class="shrink-0 rounded bg-muted px-1.5 text-xs text-muted-foreground"
                      >{result.room_name}</span>
                  {/if}
                </div>
                <ArrowRight
                  size={14}
                  class="shrink-0 text-muted-foreground opacity-0 group-hover:opacity-100 transition-opacity" />
              </div>
              <div
                class="text-sm text-muted-foreground whitespace-pre-line leading-relaxed line-clamp-4 break-words [overflow-wrap:anywhere]">
                {@html highlightMatch(result.snippet, query)}
              </div>
              <div class="mt-2 text-xs text-muted-foreground/60 break-words">
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
</div>
