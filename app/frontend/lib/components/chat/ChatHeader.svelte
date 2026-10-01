<script>
  import { page } from '@inertiajs/svelte';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { List } from 'phosphor-svelte';
  import ChatActionsMenu from '$lib/components/chat/ChatActionsMenu.svelte';
  import ChatTitleEditor from '$lib/components/chat/ChatTitleEditor.svelte';
  import ChatTokenStatus from '$lib/components/chat/ChatTokenStatus.svelte';
  import {
    accountChatForkPath,
    accountChatModerationPath,
    accountChatArchivePath,
    accountChatDiscardPath,
  } from '@/routes';
  import * as logging from '$lib/logging';
  import { tokenWarningLevel as getTokenWarningLevel } from '$lib/chat-utils';

  let {
    chat,
    account,
    agents = [],
    allMessages = [],
    contextTokens = 0,
    costTokens = { input: 0, output: 0 },
    costBreakdown = {},
    thresholds = { amber: 100_000, red: 150_000, critical: 200_000 },
    availableAgents = [],
    addableAgents = [],
    showAllMessages = $bindable(false),
    debugMode = $bindable(false),
    showCosts = $bindable(false),
    showMessageTelemetry = $bindable(false),
    onsidebaropen,
    onassignagent,
    onaddagent,
    onwhiteboardopen,
    onerror,
    onsuccess,
  } = $props();

  // Check if current user is a site admin
  const isSiteAdmin = $derived($page.props.user?.site_admin ?? false);

  // Check if current user is an account admin
  const isAccountAdmin = $derived($page.props.is_account_admin ?? false);

  // Check if user can delete chats (account admin or site admin)
  const canDeleteChat = $derived(isAccountAdmin || isSiteAdmin);

  // Token warning level — based on active context, not lifetime cost
  const tokenWarningLevel = $derived(getTokenWarningLevel(contextTokens, thresholds));

  // Header class computed based on token warning level
  const headerClass = $derived(
    tokenWarningLevel === 'critical'
      ? 'border-b border-border px-4 md:px-6 py-3 md:py-4 bg-red-50 dark:bg-red-950/30'
      : 'border-b border-border px-4 md:px-6 py-3 md:py-4 bg-muted/30'
  );

  // Check if title is loading (no title yet but has messages) - cosmetic only
  const titleIsLoading = $derived(chat && !chat.title && allMessages?.length > 0);

  function saveTitle(newTitle, previousTitle) {
    if (!chat) return;
    // Optimistically update the UI
    chat.title = newTitle;

    router.patch(
      `/accounts/${account.id}/chats/${chat.id}`,
      {
        chat: { title: newTitle },
      },
      {
        preserveScroll: true,
        preserveState: true,
        onSuccess: () => {
          logging.debug('Title updated successfully');
        },
        onError: (errors) => {
          logging.error('Failed to update title:', errors);
          // Revert to original title on error
          chat.title = previousTitle;
          onerror?.('Failed to update title');
        },
      }
    );
  }

  function toggleWebAccess() {
    if (!chat) return;

    router.patch(
      `/accounts/${account.id}/chats/${chat.id}`,
      {
        chat: { web_access: !chat.web_access },
      },
      {
        preserveScroll: true,
        preserveState: true,
        onSuccess: () => {
          logging.debug('Web access toggled successfully');
        },
        onError: (errors) => {
          logging.error('Failed to toggle web access:', errors);
        },
      }
    );
  }

  function forkConversation() {
    if (!chat) return;

    const defaultTitle = `${chat.title_or_default} (Fork)`;
    const newTitle = prompt('Enter a name for the forked conversation:', defaultTitle);
    if (newTitle === null) return; // User cancelled

    router.post(accountChatForkPath(account.id, chat.id), { title: newTitle });
  }

  function archiveChat() {
    if (!chat) return;
    if (chat.archived) {
      router.delete(accountChatArchivePath(account.id, chat.id), { preserveScroll: true });
    } else {
      router.post(accountChatArchivePath(account.id, chat.id), {}, { preserveScroll: true });
    }
  }

  function dismissReplyRequest() {
    const through = allMessages?.at(-1)?.id;
    if (!chat || !through) return;
    router.post(
      `/accounts/${account.id}/chats/${chat.id}/reply_dismissal`,
      { through_message_id: through },
      { preserveScroll: true, preserveState: true }
    );
  }

  function deleteChat() {
    if (!chat) return;
    if (!chat.discarded && !confirm('Are you sure you want to delete this conversation?')) return;
    if (chat.discarded) {
      router.delete(accountChatDiscardPath(account.id, chat.id), { preserveScroll: true });
    } else {
      router.post(accountChatDiscardPath(account.id, chat.id), {}, { preserveScroll: true });
    }
  }

  // Moderate all messages in the chat (site admin only)
  async function moderateAllMessages() {
    try {
      const response = await fetch(accountChatModerationPath(account.id, chat.id), {
        method: 'POST',
        headers: {
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
          Accept: 'application/json',
        },
      });

      if (response.ok) {
        const data = await response.json();
        onsuccess?.(`Queued moderation for ${data.queued} messages`);
      } else {
        onerror?.('Failed to queue moderation');
      }
    } catch (error) {
      onerror?.('Failed to queue moderation');
    }
  }
</script>

<header class={headerClass}>
  <div class="flex items-center gap-3">
    <Button variant="ghost" size="sm" onclick={() => onsidebaropen?.()} class="h-8 w-8 p-0 md:hidden">
      <List size={20} />
    </Button>
    <div class="flex-1 min-w-0">
      <ChatTitleEditor {chat} {titleIsLoading} onSaveTitle={saveTitle} />
      <ChatTokenStatus {chat} {agents} {allMessages} {contextTokens} {costTokens} {costBreakdown} {tokenWarningLevel} />
    </div>

    <ChatActionsMenu
      replyRequested={($page.props?.reply_attention?.chats?.[chat?.id] || 0) > 0}
      onDismissReply={dismissReplyRequest}
      {chat}
      {availableAgents}
      {addableAgents}
      {canDeleteChat}
      {isSiteAdmin}
      bind:showAllMessages
      bind:debugMode
      bind:showCosts
      bind:showMessageTelemetry
      onToggleWebAccess={toggleWebAccess}
      onAssignAgent={() => onassignagent?.()}
      onAddAgent={() => onaddagent?.()}
      onFork={forkConversation}
      onWhiteboardOpen={() => onwhiteboardopen?.()}
      onArchive={archiveChat}
      onDelete={deleteChat}
      onModerateAll={moderateAllMessages} />
  </div>
</header>
