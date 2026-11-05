<script>
  // The lines under the voice-mode controls: what the page is not hearing, the
  // last note, the reply being read, the live caption, the provisional text
  // waiting for its clean transcript, and the last sent turn.
  import PhononStatus from './PhononStatus.svelte';
  import { accountSpeechEngine } from '$lib/speech-source';

  let { stale = false, note = '', speaking = null, caption = '', provisional = '', heard = '' } = $props();
</script>

<!-- Under Phonon: its first download, its start-up, or why it can't speak. -->
{#if $accountSpeechEngine === 'phonon'}<PhononStatus testid="voice-mode-phonon-status" />{/if}

{#if stale}
  <p class="text-xs text-amber-700 dark:text-amber-400" data-testid="voice-mode-stale">
    No sound is reaching the page. If the screen locked or the tab went to the background, the browser may have paused
    the microphone; bring the page back to the front.
  </p>
{/if}
{#if note}
  <p class="text-xs text-muted-foreground" data-testid="voice-mode-note">{note}</p>
{/if}
{#if speaking}
  <p class="text-sm line-clamp-4" data-testid="voice-mode-reply">
    <span class="font-medium">{speaking.author_name || 'Reply'}:</span>
    {speaking.content}
  </p>
{/if}
{#if caption}
  <p class="text-sm" data-testid="voice-mode-caption">{caption}</p>
{/if}
{#if provisional}
  <p class="text-sm text-muted-foreground animate-pulse" data-testid="voice-mode-provisional">
    {provisional} <span class="text-xs">(in progress)</span>
  </p>
{/if}
{#if heard}
  <p class="text-xs text-muted-foreground truncate" data-testid="voice-mode-heard">Sent: “{heard}”</p>
{/if}
