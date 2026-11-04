export function buildChatSubscriptions({ account, chat }) {
  const subscriptions = {};

  if (chat) {
    subscriptions[`Chat:${chat.id}`] = ['chat', 'messages', 'runtime_interactions', 'cost_breakdown', 'agents'];
    subscriptions[`Chat:${chat.id}:messages`] = 'messages';
    // The account's voice engine or voice mode switch changing reaches an open
    // conversation, so the voice panel stops reading with the old engine
    // (SpeechEngine, Mira in jEDyze). A change to the site's scope reaches it
    // the same way: VoiceModeInvalidationJob sends a content-free marker to
    // every account's stream (Setting:all stays admin-only).
    subscriptions[`Account:${account.id}`] = ['voice_mode'];

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
