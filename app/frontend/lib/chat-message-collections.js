import { combinePaginatedMessages } from './chat-pagination-state';

export function patchMessageInCollections({ recentMessages = [], olderMessages = [], messageId, patch = {} }) {
  return {
    recentMessages: recentMessages.map((message) => (message.id === messageId ? { ...message, ...patch } : message)),
    olderMessages: olderMessages.map((message) => (message.id === messageId ? { ...message, ...patch } : message)),
  };
}

export function removeMessageFromCollections({ recentMessages = [], olderMessages = [], messageId }) {
  const all = combinePaginatedMessages(olderMessages, recentMessages).sort(
    (a, b) => new Date(a.created_at) - new Date(b.created_at)
  );
  const previous = all[all.findIndex((message) => message.id === messageId) - 1];
  const remove = (messages) =>
    messages
      .filter((message) => message.id !== messageId)
      .map((message) =>
        previous?.progress_message && message.id === previous.id ? { ...message, progress_break_after: true } : message
      );
  return { recentMessages: remove(recentMessages), olderMessages: remove(olderMessages) };
}

export function appendMessageIfMissing(messages = [], message) {
  if (!message?.id) return messages;
  if (messages.some((existingMessage) => existingMessage.id === message.id)) return messages;

  return [...messages, message];
}
