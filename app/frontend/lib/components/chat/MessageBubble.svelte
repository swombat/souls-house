<script>
  import AssistantMessageSection from './assistant-message-section.svelte';

  import * as Card from '$lib/components/shadcn/card/index.js';
  import { PencilSimple, Trash } from 'phosphor-svelte';
  import FileAttachment from '$lib/components/chat/FileAttachment.svelte';
  import StoneCards from '$lib/components/chat/StoneCards.svelte';
  import ReplyAttentionEye from './ReplyAttentionEye.svelte';

  import ModerationIndicator from '$lib/components/chat/ModerationIndicator.svelte';
  import AudioPlayer from '$lib/components/chat/AudioPlayer.svelte';
  import RhythmProvenanceBadge from '$lib/components/chat/RhythmProvenanceBadge.svelte';

  import { Streamdown } from 'svelte-streamdown';
  import CommitRef from '$lib/components/chat/CommitRef.svelte';
  import { commitRefExtensions } from '$lib/commit-refs.js';
  import { formatTime, formatDateTime } from '$lib/utils';

  import { elapsedBetween } from '$lib/progress-messages';

  let {
    message,
    accountId,
    chatId,
    progressMessages = [],
    progressContinued = false,
    isLastVisible = false,
    isGroupChat = false,
    showMessageTelemetry = false,
    streamingThinking = '',
    sectionThinking = {},
    shikiTheme = 'catppuccin-latte',
    onedit,
    ondelete,
    onimagelightbox,
    onvoice,
  } = $props();

  // Generate bubble background class based on author colour
  function getBubbleClass(colour) {
    if (!colour) return '';
    return `bg-${colour}-100 dark:bg-${colour}-900`;
  }
</script>

{#snippet expressionTag({ token })}
  <span class="expression-tag">{token.text}</span>
{/snippet}

{#snippet commitRefs({ token, streamdown })}
  {#if token.type === 'commitRef'}
    <CommitRef {token} theme={streamdown.theme} live={message.streaming !== true} />
  {/if}
{/snippet}

<div class="space-y-1">
  {#if message.role === 'user'}
    <div class="flex justify-end group">
      <div class="min-w-0 max-w-[85%] md:max-w-[70%]">
        <RhythmProvenanceBadge provenance={message.rhythm_provenance} />
        <div class="flex justify-end items-center gap-2">
          {#if message.editable}
            <button
              onclick={() => onedit(message)}
              class="shrink-0 p-1.5 rounded-full text-muted-foreground/50 hover:text-muted-foreground hover:bg-muted
                     opacity-50 hover:opacity-100 md:opacity-0 md:group-hover:opacity-100 transition-opacity
                     focus:opacity-100 focus:outline-none focus:ring-2 focus:ring-ring"
              title="Edit message">
              <PencilSimple size={20} weight="regular" />
            </button>
          {/if}
          {#if message.deletable}
            <button
              onclick={() => ondelete(message.id)}
              class="shrink-0 p-1.5 rounded-full text-muted-foreground/50 hover:text-red-500 hover:bg-red-50 dark:hover:bg-red-950
                     opacity-50 hover:opacity-100 md:opacity-0 md:group-hover:opacity-100 transition-opacity
                     focus:opacity-100 focus:outline-none focus:ring-2 focus:ring-ring"
              title="Delete message">
              <Trash size={20} weight="regular" />
            </button>
          {/if}
          <Card.Root class="{getBubbleClass(message.author_colour)} min-w-0 w-fit">
            <Card.Content class="p-4">
              <ReplyAttentionEye {accountId} {chatId} messageId={message.id} />
              <StoneCards stones={message.stones_json || []} />
              {#if message.files_json && message.files_json.length > 0}
                <div class="space-y-2 mb-3">
                  {#each message.files_json as file}
                    <FileAttachment {file} onImageClick={onimagelightbox} />
                  {/each}
                </div>
              {/if}
              <Streamdown
                content={message.content}
                parseIncompleteMarkdown={message.streaming === true}
                inlineCitation={expressionTag}
                extensions={commitRefExtensions}
                children={commitRefs}
                baseTheme="shadcn"
                {shikiTheme}
                shikiPreloadThemes={['catppuccin-latte', 'catppuccin-mocha']}
                class="prose [overflow-wrap:anywhere]" />
            </Card.Content>
          </Card.Root>
        </div>
        <div class="text-xs text-muted-foreground text-right mt-1 flex items-center justify-end gap-2">
          <span class="group">
            <span class="hidden group-hover:inline-block">({formatDateTime(message.created_at, true)})</span>
            {formatTime(message.created_at)}
          </span>
          {#if isGroupChat && message.author_name}
            <span class="ml-1">· {message.author_name}</span>
          {/if}
          {#if message.moderation_scores}
            <ModerationIndicator scores={message.moderation_scores} />
          {/if}
        </div>
        {#if message.audio_source && message.audio_url}
          <div class="mt-1 flex justify-end">
            <AudioPlayer src={message.audio_url} />
          </div>
        {/if}
      </div>
    </div>
  {:else}
    <div class="flex justify-start group">
      <div class="min-w-0 max-w-[85%] md:max-w-[70%]">
        <Card.Root class={getBubbleClass(message.author_colour)}>
          <Card.Content class="p-4">
            {#if progressContinued}
              <div class="text-xs text-muted-foreground mb-3">Continued</div>
            {/if}
            <div data-testid="message-group" aria-live="polite" aria-relevant="additions" aria-atomic="false">
              {#each progressMessages.length ? progressMessages : [message] as section, sectionIndex (section.id)}
                <section
                  data-progress-section={section.id}
                  aria-label={`${section.author_name || 'Assistant'} update at ${formatDateTime(section.created_at)}`}>
                  {#if sectionIndex > 0}
                    <div
                      class="flex items-center gap-3 my-4 text-xs text-muted-foreground"
                      title="Wall-clock time between published updates, including waits">
                      <div class="flex-1 border-t border-border"></div>
                      <span
                        >{elapsedBetween(progressMessages[sectionIndex - 1].created_at, section.created_at) ||
                          formatTime(section.created_at)}</span>
                      <div class="flex-1 border-t border-border"></div>
                    </div>
                  {/if}
                  <ReplyAttentionEye {accountId} {chatId} messageId={section.id} />
                  <AssistantMessageSection
                    message={section}
                    streamingThinking={sectionThinking[section.id] ||
                      (section.id === message.id ? streamingThinking : '')}
                    {isGroupChat}
                    {showMessageTelemetry}
                    {shikiTheme}
                    {onimagelightbox}
                    {onvoice} />
                </section>
              {/each}
            </div>
          </Card.Content>
        </Card.Root>
      </div>
    </div>
  {/if}
</div>
