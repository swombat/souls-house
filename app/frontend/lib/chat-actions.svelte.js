import { onDestroy } from 'svelte';
import { router } from '@inertiajs/svelte';
import { accountChatAgentAssignmentPath, accountChatParticipantPath, messagePath } from '@/routes';
import { listen, resetListen } from '$lib/listen';

export function createChatActions(context, history) {
  const ui = $state({
    whiteboardOpen: false,
    assignAgentOpen: false,
    assigningAgent: false,
    addAgentOpen: false,
    addAgentProcessing: false,
    lightboxOpen: false,
    lightboxImage: null,
    editDrawerOpen: false,
    editingMessageId: null,
    editingContent: '',
    editReturnFocus: null,
    errorMessage: null,
    successMessage: null,
  });
  const timers = {};
  onDestroy(() => {
    Object.values(timers).forEach(clearTimeout);
    resetListen();
  });
  function notify(message, kind = 'errorMessage') {
    clearTimeout(timers[kind]);
    ui[kind] = message;
    timers[kind] = setTimeout(() => (ui[kind] = null), 5000);
  }
  function csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || '';
  }
  function assignToAgent(agentId) {
    const { chat, account } = context();
    if (!chat || !agentId) return;
    ui.assigningAgent = true;
    router.post(
      accountChatAgentAssignmentPath(account.id, chat.id),
      { agent_id: agentId },
      {
        onFinish: () => {
          ui.assigningAgent = false;
          ui.assignAgentOpen = false;
        },
      }
    );
  }
  function addAgentToChat(agentId) {
    const { chat, account } = context();
    if (!chat || !agentId) return;
    ui.addAgentProcessing = true;
    router.post(
      accountChatParticipantPath(account.id, chat.id),
      { agent_id: agentId },
      {
        onFinish: () => {
          ui.addAgentProcessing = false;
          ui.addAgentOpen = false;
        },
      }
    );
  }
  async function deleteMessage(messageId) {
    if (!confirm('Delete this message?')) return;
    const chatId = context().chat.id;
    try {
      const response = await fetch(messagePath(messageId), {
        method: 'DELETE',
        headers: { 'X-CSRF-Token': csrfToken() },
      });
      if (context().chat.id !== chatId) return;
      if (!response.ok) throw new Error('Failed to delete message');
      history.remove(messageId);
      router.reload({ only: ['messages'], preserveScroll: true });
    } catch {
      if (context().chat.id === chatId) notify('Failed to delete message');
    }
  }
  // Listen (SpeechEngine, jEDyze): lib/listen.js owns the state and the
  // audio; this supplies the ElevenLabs request for its stored audio.
  async function postVoice(messageId, { signal } = {}) {
    const response = await fetch(`/messages/${messageId}/voice`, {
      method: 'POST',
      headers: { 'X-CSRF-Token': csrfToken(), Accept: 'application/json' },
      signal,
    });
    if (response.status === 200) return { url: (await response.json()).voice_audio_url };
    if (response.status === 202) return { pending: true };
    const body = await response.json().catch(() => ({}));
    return { error: body.error || body.message || 'This message could not be read aloud.' };
  }
  function requestVoice(messageId) {
    return listen(messageId, { postVoice });
  }
  return {
    ui,
    notify,
    assignToAgent,
    addAgentToChat,
    deleteMessage,
    requestVoice,
    openImage(file) {
      ui.lightboxImage = file;
      ui.lightboxOpen = true;
    },
    // returnFocus: where focus goes when the drawer closes (the composer, when
    // the up-arrow shortcut opened it).
    edit(message, { returnFocus = null } = {}) {
      ui.editingMessageId = message.id;
      ui.editingContent = message.content;
      ui.editReturnFocus = returnFocus;
      ui.editDrawerOpen = true;
    },
    editClosed() {
      const target = ui.editReturnFocus;
      ui.editReturnFocus = null;
      if (!target?.isConnected || target.disabled) return false;
      setTimeout(() => target.focus(), 0);
      return true;
    },
    editSaved(messageId, content) {
      // The author can edit again (Message#editable is not one-shot); the reload brings the rest.
      history.update(messageId, { content });
      ui.editDrawerOpen = false;
      ui.editingMessageId = null;
      ui.editingContent = '';
    },
  };
}
