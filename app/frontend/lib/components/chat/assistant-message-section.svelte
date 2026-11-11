<script>
  import { Badge } from '$lib/components/shadcn/badge/index.js';

  import { Spinner, Globe, SpeakerSimpleHigh, LightbulbFilament } from 'phosphor-svelte';
  import FileAttachmentList from '$lib/components/chat/FileAttachmentList.svelte';
  import StoneCards from '$lib/components/chat/StoneCards.svelte';
  import RichUi from '$lib/components/chat/rich-ui/rich-ui.svelte';
  import { richMessageProse } from '$lib/rich-ui.js';
  import TweetCards from '$lib/components/chat/TweetCards.svelte';
  import ThinkingBlock from '$lib/components/chat/ThinkingBlock.svelte';
  import ModerationIndicator from '$lib/components/chat/ModerationIndicator.svelte';
  import AudioPlayer from '$lib/components/chat/AudioPlayer.svelte';
  import PhononStatus from '$lib/components/chat/PhononStatus.svelte';
  import { listenState } from '$lib/listen';
  import MessageTelemetry from '$lib/components/chat/MessageTelemetry.svelte';
  import HandoffReceipts from '$lib/components/chat/HandoffReceipts.svelte';
  import SongReferenceParagraph from './SongReferenceParagraph.svelte';
  import { Streamdown } from 'svelte-streamdown';
  import { LINK_PREFIXES } from '$lib/markdown-links.js';
  import CommitRef from '$lib/components/chat/CommitRef.svelte';
  import ConversationRef from '$lib/components/chat/ConversationRef.svelte';
  import { messageRefExtensions } from '$lib/message-refs.js';
  import { formatTime, formatDateTime } from '$lib/utils';
  import { reasoningSkipTooltip } from '$lib/chat-utils';

  import { formatToolsUsed } from '$lib/chat-message-formatting';

  let {
    message,
    accountId,
    streamingThinking = '',
    isGroupChat = false,
    showMessageTelemetry = false,
    shikiTheme,
    onimagelightbox,
    onvoice,
  } = $props();
  let prose = $derived(richMessageProse(message.content, message.rich_ui));
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

{#snippet commitRefs({ token, streamdown })}
  {#if token.type === 'commitRef'}
    <CommitRef {token} theme={streamdown.theme} live={message.streaming !== true} />
  {:else if token.type === 'conversationRef'}
    <ConversationRef {token} theme={streamdown.theme} live={message.streaming !== true} />
  {/if}
{/snippet}

{#snippet songParagraph({ token, children })}
  <SongReferenceParagraph {token} {children} {accountId} messageId={message.id} />
{/snippet}

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
    allowedLinkPrefixes={LINK_PREFIXES}
    content={prose.content}
    parseIncompleteMarkdown={message.streaming === true}
    inlineCitation={expressionTag}
    extensions={messageRefExtensions}
    children={commitRefs}
    paragraph={songParagraph}
    baseTheme="shadcn"
    {shikiTheme}
    shikiPreloadThemes={['catppuccin-latte', 'catppuccin-mocha']}
    class="prose [overflow-wrap:anywhere]" />
  <RichUi value={message.rich_ui} />
  {#if prose.fallback}
    <details class="my-2 text-sm" data-testid="rich-ui-fallback">
      <summary class="cursor-pointer text-muted-foreground underline">Text fallback</summary>
      <p class="whitespace-pre-wrap [overflow-wrap:anywhere]">{prose.fallback}</p>
    </details>
  {/if}
  <TweetCards tweets={message.tweet_embeds_json || []} />
{/if}

<StoneCards stones={message.stones_json || []} />

{#if message.files_json && message.files_json.length > 0}
  <FileAttachmentList
    files={message.files_json}
    onImageClick={onimagelightbox}
    class={message.content || message.thinking || streamingThinking ? 'mt-3' : ''} />
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
<div class="text-xs text-muted-foreground mt-1 flex flex-wrap items-center gap-x-2 gap-y-1">
  <div class="flex items-center gap-2">
    {#if message.moderation_scores}
      <ModerationIndicator scores={message.moderation_scores} />
    {/if}
    {#if isGroupChat && message.author_name}
      <span>{message.author_name}</span>
      <span>·</span>
    {/if}
    {#if message.runtime_model_label}
      <span data-testid="answer-model" title="The model that produced this answer">{message.runtime_model_label}</span>
      <span>·</span>
    {/if}
    {#if message.paid_fallback}
      <span
        data-testid="paid-fallback-label"
        class="rounded border border-amber-500/40 bg-amber-500/10 px-1.5 text-amber-800 dark:text-amber-300"
        title="The subscription's allowance had run out, so this answer ran on the paid fallback the account's owner turned on.">
        Paid fallback · via {message.paid_fallback.provider_label} · {message.paid_fallback.payer_label}
      </span>
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
<HandoffReceipts receipts={message.handoff_receipts || []} />
{#if message.voice_available && !message.streaming}
  {@const heard = $listenState[message.id]}
  <div class="mt-1">
    {#if heard?.url}
      <AudioPlayer src={heard.url} autoplay />
    {:else if message.voice_audio_url}
      <AudioPlayer src={message.voice_audio_url} />
    {:else if heard?.status === 'loading' || heard?.status === 'pending' || message._voice_loading}
      <div class="inline-flex items-center gap-1.5 text-xs text-muted-foreground" data-testid="listen-loading">
        <Spinner size={14} class="animate-spin" />
        <span>Generating voice...</span>
      </div>
      <PhononStatus testid="listen-phonon-status" />
    {:else}
      {#if heard?.error}
        <p class="text-xs text-destructive" data-testid="listen-error">{heard.error}</p>
      {/if}
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
