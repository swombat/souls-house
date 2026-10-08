import { onMount } from 'svelte';
import { mergeRuntimeActivity, runtimeActivityNeedsMessageRefresh } from './runtime-activity';
import { reloadProps } from './cable';

export function createChatRuntimeActivity(context) {
  let updates = $state({ chatId: null, rows: [], snapshot: [] });
  const rows = $derived(
    mergeRuntimeActivity(context().initial, updates.chatId === context().chat.id ? updates.rows : [])
  );
  const needsRefresh = $derived(
    updates.chatId === context().chat.id && runtimeActivityNeedsMessageRefresh(context().initial, updates.snapshot)
  );

  onMount(() => {
    let disposed = false;
    let inFlight = false;
    let refreshAgain = false;
    const controller = new AbortController();
    async function refreshActivity() {
      if (inFlight) {
        refreshAgain = true;
        return;
      }
      const { chat, account } = context();
      const chatId = chat.id;
      inFlight = true;
      try {
        const response = await fetch(`/accounts/${account.id}/chats/${chatId}/activity`, {
          signal: controller.signal,
          headers: { Accept: 'application/json' },
        });
        if (!response.ok) return;
        const data = await response.json();
        if (!disposed && context().chat.id === chatId) {
          updates = {
            chatId,
            snapshot: data.runtime_interactions || [],
            rows: mergeRuntimeActivity(updates.chatId === chatId ? updates.rows : [], data.runtime_interactions || []),
          };
          if (needsRefresh) reloadProps(['chat', 'messages', 'runtime_interactions', 'cost_breakdown', 'agents']);
        }
      } catch {
        // A failed read does not mean execution failed; keep the persisted card.
      } finally {
        inFlight = false;
        if (refreshAgain && !disposed) {
          refreshAgain = false;
          refreshActivity();
        }
      }
    }
    const onVisible = () => {
      if (!document.hidden) refreshActivity();
    };
    window.addEventListener('runtime-activity-refresh', refreshActivity);
    document.addEventListener('visibilitychange', onVisible);
    const interval = setInterval(() => {
      if (!document.hidden && (rows.some((row) => row.active) || needsRefresh)) refreshActivity();
    }, 5000);
    refreshActivity();
    return () => {
      disposed = true;
      controller.abort();
      clearInterval(interval);
      window.removeEventListener('runtime-activity-refresh', refreshActivity);
      document.removeEventListener('visibilitychange', onVisible);
    };
  });
  return {
    get rows() {
      return rows;
    },
  };
}
