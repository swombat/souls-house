<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Badge } from '$lib/components/shadcn/badge/index.js';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Spinner, Globe, PencilSimple, SpeakerSimpleHigh, Trash, LightbulbFilament } from 'phosphor-svelte';
  import FileAttachment from '$lib/components/chat/FileAttachment.svelte';
  import ThinkingBlock from '$lib/components/chat/ThinkingBlock.svelte';
  import ModerationIndicator from '$lib/components/chat/ModerationIndicator.svelte';
  import AudioPlayer from '$lib/components/chat/AudioPlayer.svelte';
  import MessageTelemetry from '$lib/components/chat/MessageTelemetry.svelte';
  import { Streamdown } from 'svelte-streamdown';
  import { formatTime, formatDateTime } from '$lib/utils';
  import { reasoningSkipTooltip } from '$lib/chat-utils';
  import { formatToolsUsed } from '$lib/chat-message-formatting';

  let {
    message,
    isLastVisible = false,
    isGroupChat = false,
    showMessageTelemetry = false,
    streamingThinking = '',
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

  function dollars(value) {
    if (value === null || value === undefined) return null;

    const amount = Number(value);
    const digits = amount < 0.01 ? 4 : 2;
    return `≈${new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: 'USD',
      minimumFractionDigits: digits,
      maximumFractionDigits: digits,
    }).format(amount)}`;
  }
</script>

{#snippet expressionTag({ token })}
  <span class="expression-tag">{token.text}</span>
{/snippet}

<div class="space-y-1">
  {#if message.role === 'user'}
    <div class="flex justify-end group">
      <div class="max-w-[85%] md:max-w-[70%]">
        <div class="flex justify-end items-center gap-2">
          {#if message.editable}
            <button
              onclick={() => onedit(message)}
              class="p-1.5 rounded-full text-muted-foreground/50 hover:text-muted-foreground hover:bg-muted
                     opacity-50 hover:opacity-100 md:opacity-0 md:group-hover:opacity-100 transition-opacity
                     focus:opacity-100 focus:outline-none focus:ring-2 focus:ring-ring"
              title="Edit message">
              <PencilSimple size={20} weight="regular" />
            </button>
          {/if}
          {#if message.deletable}
            <button
              onclick={() => ondelete(message.id)}
              class="p-1.5 rounded-full text-muted-foreground/50 hover:text-red-500 hover:bg-red-50 dark:hover:bg-red-950
                     opacity-50 hover:opacity-100 md:opacity-0 md:group-hover:opacity-100 transition-opacity
                     focus:opacity-100 focus:outline-none focus:ring-2 focus:ring-ring"
              title="Delete message">
              <Trash size={20} weight="regular" />
            </button>
          {/if}
          <Card.Root class="{getBubbleClass(message.author_colour)} w-fit">
            <Card.Content class="p-4">
              {#if message.files_json && message.files_json.length > 0}
                <div class="space-y-2 mb-3">
                  {#each message.files_json as file}
                    <FileAttachment {file} onImageClick={onimagelightbox} />
                  {/each}
                </div>
              {/if}
              <Streamdown
                content={message.content}
                inlineCitation={expressionTag}
                baseTheme="shadcn"
                {shikiTheme}
                shikiPreloadThemes={['catppuccin-latte', 'catppuccin-mocha']}
                class="prose" />
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
      <div class="max-w-[85%] md:max-w-[70%]">
        <Card.Root class={getBubbleClass(message.author_colour)}>
          <Card.Content class="p-4">
            {#if message.status === 'failed'}
              <div class="text-red-600 mb-2 text-sm">Failed to generate response</div>
            {:else if message.status === 'pending'}
              <div class="text-muted-foreground text-sm">Thinking...</div>
            {:else if message.streaming && (!message.content || message.content.trim() === '')}
              <div class="flex items-center gap-2 text-muted-foreground">
                <Spinner size={16} class="animate-spin" />
                <span class="text-sm">{message.tool_status || 'Generating response...'}</span>
              </div>
            {:else}
              <!-- Show thinking block if thinking content exists -->
              {#if message.thinking || streamingThinking}
                <ThinkingBlock
                  content={message.thinking || streamingThinking || ''}
                  isStreaming={message.streaming && !message.thinking}
                  preview={message.thinking_preview} />
              {/if}

              <Streamdown
                content={message.content}
                inlineCitation={expressionTag}
                baseTheme="shadcn"
                {shikiTheme}
                shikiPreloadThemes={['catppuccin-latte', 'catppuccin-mocha']}
                class="prose" />
            {/if}

            {#if message.files_json && message.files_json.length > 0}
              <div class:mt-3={message.content || message.thinking || streamingThinking} class="space-y-2">
                {#each message.files_json as file}
                  <FileAttachment {file} onImageClick={onimagelightbox} />
                {/each}
              </div>
            {/if}

            {#if message.tools_used && message.tools_used.length > 0}
              <div class="flex items-center gap-2 mt-3 pt-3 border-t border-border/50">
                <Globe size={14} class="text-muted-foreground" weight="duotone" />
                <div class="flex flex-wrap gap-1">
                  {#each formatToolsUsed(message.tools_used) as tool}
                    <Badge variant="secondary" class="text-xs">
                      {tool}
                    </Badge>
                  {/each}
                </div>
              </div>
            {/if}
          </Card.Content>
        </Card.Root>
        <div class="text-xs text-muted-foreground mt-1 flex flex-wrap items-center gap-x-2 gap-y-1">
          <div class="flex items-center gap-2">
            {#if message.moderation_scores}
              <ModerationIndicator scores={message.moderation_scores} />
            {/if}
            {#if isGroupChat && message.author_name}
              <span>{message.author_name}</span>
              <span>·</span>
            {/if}
            {#if message.interaction_cost?.amount_usd}
              <span
                class:line-through={message.interaction_cost.applies_to_billing === false}
                title={message.interaction_cost.applies_to_billing === false
                  ? 'This activation used a provider subscription, so this API-equivalent estimate does not apply.'
                  : `Estimated interaction cost using ${message.interaction_cost.pricing_as_of} prices`}>
                {dollars(message.interaction_cost.amount_usd)}
              </span>
              <span>·</span>
            {/if}
            <span class="group">
              {formatTime(message.created_at)}
              <span class="hidden group-hover:inline-block">({formatDateTime(message.created_at, true)})</span>
            </span>
            {#if message.reasoning_skip_reason}
              <span
                title={message.reasoning_skip_reason_label || reasoningSkipTooltip(message.reasoning_skip_reason)}
                class="text-muted-foreground inline-flex items-center"
                aria-label="Thinking unavailable for this message">
                <LightbulbFilament size={14} />
              </span>
            {/if}
            {#if message.status === 'pending'}
              <span class="ml-2 text-blue-600">...</span>
            {:else if message.streaming}
              <span class="ml-2 text-green-600 animate-pulse">...</span>
            {/if}
          </div>
          {#if showMessageTelemetry && message.ruby_llm_telemetry}
            <MessageTelemetry telemetry={message.ruby_llm_telemetry} />
          {/if}
        </div>
        {#if message.voice_available && !message.streaming}
          <div class="mt-1">
            {#if message.voice_audio_url}
              <AudioPlayer src={message.voice_audio_url} />
            {:else if message._voice_loading}
              <div class="inline-flex items-center gap-1.5 text-xs text-muted-foreground">
                <Spinner size={14} class="animate-spin" />
                <span>Generating voice...</span>
              </div>
            {:else}
              <button
                onclick={() => onvoice(message.id)}
                class="inline-flex items-center gap-1.5 text-xs text-muted-foreground
                       hover:text-foreground transition-colors"
                title="Play voice">
                <SpeakerSimpleHigh size={14} weight="duotone" />
                <span>Listen</span>
              </button>
            {/if}
          </div>
        {/if}
      </div>
    </div>
  {/if}
</div>
