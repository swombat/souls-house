export function buildChatSubscriptions({ account, chat }) {
  const subscriptions = {};

  if (chat) {
    subscriptions[`Chat:${chat.id}`] = ['chat', 'messages', 'runtime_interactions', 'cost_breakdown', 'agents'];
    subscriptions[`Chat:${chat.id}:messages`] = 'messages';

    if (chat.active_whiteboard) {
      subscriptions[`Whiteboard:${chat.active_whiteboard.id}`] = ['chat', 'messages'];
    }
  }

  return subscriptions;
}

export function chatSyncSignature({ account, chat }) {
  // Only channel identity changes require resubscription. Reconnecting after
  // every message also causes a catch-up reload for each new subscription.
  return `${account.id}|${chat?.id ?? 'none'}|${chat?.active_whiteboard?.id ?? 'none'}`;
}
