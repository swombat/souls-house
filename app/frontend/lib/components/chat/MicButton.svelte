<script>
  import { Microphone, MicrophoneSlash, Spinner } from 'phosphor-svelte';

  const MIN_AUDIO_BYTES = 1000;

  let { disabled = false, accountId, chatId, onsuccess, onerror } = $props();

  let state = $state('idle');

  let mediaRecorder = null;
  let audioChunks = [];

  const isRecording = $derived(state === 'recording');
  const isTranscribing = $derived(state === 'transcribing');

  async function toggleRecording() {
    if (isRecording) {
      stopRecording();
    } else if (state === 'idle') {
      await startRecording();
    }
  }

  async function startRecording() {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });

      const mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus')
        ? 'audio/webm;codecs=opus'
        : MediaRecorder.isTypeSupported('audio/webm')
          ? 'audio/webm'
          : MediaRecorder.isTypeSupported('audio/mp4')
            ? 'audio/mp4'
            : '';

      const options = mimeType ? { mimeType } : {};
      const recorder = new MediaRecorder(stream, options);
      audioChunks = [];

      recorder.ondataavailable = (event) => {
        if (event.data.size > 0) {
          audioChunks.push(event.data);
        }
      };

      recorder.onstop = async () => {
        stream.getTracks().forEach((track) => track.stop());

        if (audioChunks.length === 0) {
          state = 'idle';
          return;
        }

        const actualMimeType = recorder.mimeType || 'audio/webm';
        const blob = new Blob(audioChunks, { type: actualMimeType });
        audioChunks = [];

        if (blob.size < MIN_AUDIO_BYTES) {
          state = 'idle';
          onerror?.('Recording too short');
          return;
        }

        await transcribe(blob, actualMimeType);
      };

      recorder.start();
      mediaRecorder = recorder;
      state = 'recording';
    } catch (err) {
      state = 'idle';
      if (err.name === 'NotAllowedError') {
        onerror?.('Microphone access denied. Please allow microphone access in your browser settings.');
      } else if (err.name === 'NotFoundError') {
        onerror?.('No microphone found. Please connect a microphone and try again.');
      } else {
        onerror?.('Could not start recording');
      }
    }
  }

  function stopRecording() {
    if (mediaRecorder && mediaRecorder.state === 'recording') {
      mediaRecorder.stop();
      state = 'transcribing';
    }
  }

  async function transcribe(blob, mimeType) {
    state = 'transcribing';

    const ext = mimeType.includes('mp4') ? 'mp4' : 'webm';
    const formData = new FormData();
    formData.append('audio', blob, `recording.${ext}`);

    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;

      const path = chatId
        ? `/accounts/${accountId}/chats/${chatId}/transcription`
        : `/accounts/${accountId}/chats/transcription`;
      const response = await fetch(path, {
        method: 'POST',
        headers: {
          'X-CSRF-Token': csrfToken,
          Accept: 'application/json',
        },
        body: formData,
      });

      const data = await response.json();

      if (response.ok && data.text) {
        onsuccess?.(data.text, data.audio_signed_id);
      } else {
        onerror?.(data.error || 'Transcription failed');
      }
    } catch (err) {
      onerror?.('Network error during transcription');
    } finally {
      state = 'idle';
    }
  }
</script>

<button
  type="button"
  onclick={toggleRecording}
  disabled={disabled || isTranscribing}
  class="h-10 w-10 p-0 inline-flex items-center justify-center rounded-md transition-colors
         {isRecording
    ? 'bg-red-500 text-white hover:bg-red-600 animate-pulse'
    : 'hover:bg-accent hover:text-accent-foreground'}
         disabled:pointer-events-none disabled:opacity-50"
  title={isRecording ? 'Stop recording' : isTranscribing ? 'Transcribing...' : 'Record voice message'}>
  {#if isTranscribing}
    <Spinner size={18} class="animate-spin" />
  {:else if isRecording}
    <MicrophoneSlash size={18} />
  {:else}
    <Microphone size={18} />
  {/if}
</button>
