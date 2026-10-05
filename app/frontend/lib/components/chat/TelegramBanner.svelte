<script>
  import { X } from 'phosphor-svelte';

  const browser = typeof window !== 'undefined';

  let { telegramDeepLink = null, agents = [], chatId = null } = $props();

  let telegramBannerDismissed = $state(false);

  // Check localStorage for previously dismissed Telegram banners
  $effect(() => {
    if (browser && chatId) {
      const dismissedAgents = JSON.parse(localStorage.getItem('telegram_banner_dismissed') || '{}');
      // Find agent id from the deep link context - use first agent's id
      const agentId = agents?.[0]?.id;
      if (agentId && dismissedAgents[agentId]) {
        telegramBannerDismissed = true;
      } else {
        telegramBannerDismissed = false;
      }
    }
  });

  function dismissTelegramBanner() {
    telegramBannerDismissed = true;
    if (browser) {
      const agentId = agents?.[0]?.id;
      if (agentId) {
        const dismissed = JSON.parse(localStorage.getItem('telegram_banner_dismissed') || '{}');
        dismissed[agentId] = true;
        localStorage.setItem('telegram_banner_dismissed', JSON.stringify(dismissed));
      }
    }
  }

  // Telegram agent name for the banner
  const telegramAgentName = $derived(
    agents?.find((a) => a.telegram_configured)?.name || agents?.[0]?.name || 'this resident'
  );
</script>

{#if telegramDeepLink && !telegramBannerDismissed}
  <div
    class="border-b border-blue-200 dark:border-blue-800 bg-blue-50 dark:bg-blue-950/30 px-4 py-2 text-sm flex items-center justify-between gap-3">
    <div>
      <span class="font-medium text-blue-800 dark:text-blue-200">Connect on Telegram</span>
      <span class="text-blue-700 dark:text-blue-300 ml-1">
        -- Exchange direct messages with {telegramAgentName}.
      </span>
      <a
        href={telegramDeepLink}
        target="_blank"
        rel="noopener noreferrer"
        class="ml-2 text-blue-600 dark:text-blue-400 underline hover:text-blue-800 dark:hover:text-blue-200">
        Connect on Telegram
      </a>
    </div>
    <button
      onclick={dismissTelegramBanner}
      class="flex-shrink-0 p-1 text-blue-400 hover:text-blue-600 dark:text-blue-500 dark:hover:text-blue-300"
      title="Dismiss">
      <X size={16} />
    </button>
  </div>
{/if}
