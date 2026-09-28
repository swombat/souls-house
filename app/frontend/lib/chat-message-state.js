const RESPONSE_TIMEOUT_MS = 60 * 1000;

export function isVisibleChatMessage(message) {
  if (message.role === 'tool') return false;
  if (message.progress_message || message.files_json?.length) return true;

  if (message.role === 'assistant' && (!message.content || message.content.trim() === '') && !message.streaming) {
    return false;
  }

  if (message.role === 'assistant' && message.content && !message.streaming) {
    const trimmed = message.content.trim();
    if (trimmed.startsWith('{')) {
      const lastBrace = trimmed.lastIndexOf('}');
      if (lastBrace !== -1 && trimmed.substring(lastBrace + 1).trim() === '') return false;
    }
  }

  return true;
}

export function visibleChatMessages(messages, showAllMessages = false) {
  if (showAllMessages) return messages;
  return messages.filter(isVisibleChatMessage);
}

export function lastMessageIsHiddenThinking(messages) {
  if (!messages || messages.length === 0) return false;
  return !isVisibleChatMessage(messages[messages.length - 1]);
}

export function lastMessageIsUserWithoutResponse(messages) {
  if (!messages || messages.length === 0) return false;
  return messages[messages.length - 1]?.role === 'user';
}

export function shouldShowSendingPlaceholder({ chat, messages, waitingForResponse }) {
  return !chat?.manual_responses && (waitingForResponse || lastMessageIsUserWithoutResponse(messages));
}

export function lastUserMessageTime(messages) {
  if (!messages || messages.length === 0) return null;
  const lastMessage = messages[messages.length - 1];
  return lastMessage?.role === 'user' ? new Date(lastMessage.created_at).getTime() : null;
}

export function isChatResponseTimedOut({ chat, messages, waitingForResponse, messageSentAt, currentTime }) {
  const messageTime = messageSentAt || lastUserMessageTime(messages);
  return (
    shouldShowSendingPlaceholder({ chat, messages, waitingForResponse }) &&
    Boolean(messageTime) &&
    currentTime - messageTime > RESPONSE_TIMEOUT_MS
  );
}

export function lastUserMessageNeedsResend(messages, currentTime) {
  if (!messages || messages.length === 0) return false;
  const lastMessage = messages[messages.length - 1];
  if (!lastMessage || lastMessage.role !== 'user') return false;

  return currentTime - new Date(lastMessage.created_at).getTime() > RESPONSE_TIMEOUT_MS;
}

export function shouldShowTimestampForMessages(messages, index) {
  if (
    !Array.isArray(messages) ||
    messages.length === 0 ||
    messages[index] === undefined ||
    Number.isNaN(new Date(messages[index].created_at))
  ) {
    return false;
  }

  if (index === 0) return true;

  const previousMessage = messages[index - 1];
  if (!previousMessage) return true;

  const createdAt = new Date(messages[index].created_at);
  const previousCreatedAt = new Date(previousMessage.created_at);
  if (Number.isNaN(previousCreatedAt)) return true;

  if (createdAt.toDateString() !== previousCreatedAt.toDateString()) return true;

  return createdAt.getTime() - previousCreatedAt.getTime() >= RESPONSE_TIMEOUT_MS * 60;
}

export function timestampLabelForMessages(messages, index, { formatDate, formatTime }) {
  const message = messages[index];
  if (!message) return '';

  const createdAt = new Date(message.created_at);
  if (Number.isNaN(createdAt)) return '';
  if (index === 0) return formatDate(createdAt);

  const previousMessage = messages[index - 1];
  const previousCreatedAt = previousMessage ? new Date(previousMessage.created_at) : null;

  if (
    !previousCreatedAt ||
    Number.isNaN(previousCreatedAt) ||
    createdAt.toDateString() !== previousCreatedAt.toDateString()
  ) {
    return formatDate(createdAt);
  }

  return formatTime(createdAt);
}
