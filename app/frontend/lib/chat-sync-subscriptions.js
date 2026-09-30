export function buildChatSubscriptions({ account, chat }) {
  const subscriptions = {};

  if (chat) {
    subscriptions[`Chat:${chat.id}`] = ['chat', 'messages', 'runtime_interactions', 'cost_breakdown'];
    subscriptions[`Chat:${chat.id}:messages`] = 'messages';

    if (chat.active_whiteboard) {
      subscriptions[`Whiteboard:${chat.active_whiteboard.id}`] = ['chat', 'messages'];
    }
  }

  return subscriptions;
}

export function chatSyncSignature({ account, chat, recentMessages }) {
  const messageSignature = Array.isArray(recentMessages) ? recentMessages.map((message) => message.id).join(':') : '';
  return `${account.id}|${chat?.id ?? 'none'}|${messageSignature}`;
}
