import { onDestroy } from 'svelte';
import { router } from '@inertiajs/svelte';
import { accountChatAgentAssignmentPath, accountChatParticipantPath, messagePath } from '@/routes';
import { createSpeechSource } from '$lib/speech-source';

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
  const listenSource = createSpeechSource({ mode: 'listen' });
  onDestroy(() => {
    Object.values(timers).forEach(clearTimeout);
    listenSource.close();
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
  // Listen (SpeechEngine, jEDyze): the server says which engine reads this
  // resident. Phonon makes the audio here and the message gets a blob URL to
  // play; ElevenLabs keeps its stored-audio path (POST /voice). A reason it
  // can't be read is shown on the message, never the other engine.
  async function requestVoice(messageId) {
    const chatId = context().chat.id;
    history.update(messageId, { _voice_loading: true, _voice_error: null });
    try {
      const answer = await listenSource.resolve(messageId);
      if (context().chat.id !== chatId) return;
      if (answer.engine === 'phonon') {
        history.update(messageId, { _speech_url: answer.url, _voice_loading: false });
        return;
      }
      const response = await fetch(`/messages/${messageId}/voice`, {
        method: 'POST',
        headers: { 'X-CSRF-Token': csrfToken(), Accept: 'application/json' },
      });
      if (context().chat.id !== chatId) return;
      if (response.status === 200) {
        const { voice_audio_url } = await response.json();
        if (context().chat.id === chatId) history.update(messageId, { voice_audio_url, _voice_loading: false });
      } else if (response.status !== 202) {
        const body = await response.json().catch(() => ({}));
        history.update(messageId, { _voice_loading: false, _voice_error: body.error || body.message || null });
      }
      // 202 is cleared by the next server-provided message window.
    } catch (error) {
      if (context().chat.id === chatId)
        history.update(messageId, {
          _voice_loading: false,
          _voice_error: error?.message || 'This message could not be read aloud.',
        });
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
