import { onDestroy } from 'svelte';
import { router } from '@inertiajs/svelte';
import { accountChatAgentAssignmentPath, accountChatParticipantPath, messagePath } from '@/routes';

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
    errorMessage: null,
    successMessage: null,
  });
  const timers = {};
  onDestroy(() => Object.values(timers).forEach(clearTimeout));
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
  async function requestVoice(messageId) {
    const chatId = context().chat.id;
    history.update(messageId, { _voice_loading: true });
    try {
      const response = await fetch(`/messages/${messageId}/voice`, {
        method: 'POST',
        headers: { 'X-CSRF-Token': csrfToken(), Accept: 'application/json' },
      });
      if (context().chat.id !== chatId) return;
      if (response.status === 200) {
        const { voice_audio_url } = await response.json();
        if (context().chat.id === chatId) history.update(messageId, { voice_audio_url, _voice_loading: false });
      } else if (response.status !== 202) history.update(messageId, { _voice_loading: false });
      // 202 is cleared by the next server-provided message window.
    } catch {
      if (context().chat.id === chatId) history.update(messageId, { _voice_loading: false });
    }
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
    edit(message) {
      ui.editingMessageId = message.id;
      ui.editingContent = message.content;
      ui.editDrawerOpen = true;
    },
    editSaved(messageId, content) {
      history.update(messageId, { content, editable: false });
      ui.editDrawerOpen = false;
      ui.editingMessageId = null;
      ui.editingContent = '';
    },
  };
}
