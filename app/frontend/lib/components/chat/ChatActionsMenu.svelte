<script>
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import {
    Globe,
    GitFork,
    Notepad,
    DotsThreeVertical,
    Robot,
    ShieldCheck,
    Archive,
    Trash,
    ArrowCounterClockwise,
    ChartBar,
    EyeSlash,
  } from 'phosphor-svelte';

  let {
    chat,
    availableAgents = [],
    addableAgents = [],
    canDeleteChat = false,
    isSiteAdmin = false,
    showAllMessages = $bindable(false),
    debugMode = $bindable(false),
    showCosts = $bindable(false),
    showMessageTelemetry = $bindable(false),
    onToggleWebAccess = () => {},
    onAssignAgent = () => {},
    onAddAgent = () => {},
    onFork = () => {},
    onWhiteboardOpen = () => {},
    onArchive = () => {},
    onDelete = () => {},
    onModerateAll = () => {},
    onDismissReply = () => {},
    replyRequested = false,
  } = $props();
</script>

{#if chat}
  <DropdownMenu.Root>
    <DropdownMenu.Trigger
      aria-label="Conversation actions"
      class="inline-flex items-center justify-center h-8 w-8 rounded-md text-sm font-medium ring-offset-background transition-colors hover:bg-accent hover:text-accent-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2">
      <DotsThreeVertical size={20} weight="bold" />
    </DropdownMenu.Trigger>
    <DropdownMenu.Content align="end" class="w-48">
      {#if replyRequested}
        <DropdownMenu.Item onclick={onDismissReply}>
          <EyeSlash size={16} class="mr-2" />
          Dismiss request to respond
        </DropdownMenu.Item>
        <DropdownMenu.Separator />
      {/if}
      {#if !chat.manual_responses}
        <DropdownMenu.CheckboxItem checked={chat.web_access} onCheckedChange={onToggleWebAccess}>
          <Globe size={16} class="mr-2" weight="duotone" />
          Allow web access
        </DropdownMenu.CheckboxItem>
        {#if availableAgents.length > 0}
          <DropdownMenu.Item onclick={onAssignAgent}>
            <Robot size={16} class="mr-2" weight="duotone" />
            Assign to Resident
          </DropdownMenu.Item>
        {/if}
        <DropdownMenu.Separator />
      {/if}
      {#if chat.manual_responses && addableAgents.length > 0}
        <DropdownMenu.Item onclick={onAddAgent}>
          <Robot size={16} class="mr-2" weight="duotone" />
          Add Resident
        </DropdownMenu.Item>
      {/if}

      <DropdownMenu.Item onclick={onFork}>
        <GitFork size={16} class="mr-2" weight="duotone" />
        Fork
      </DropdownMenu.Item>

      <DropdownMenu.CheckboxItem checked={showCosts} onCheckedChange={(checked) => (showCosts = checked)}>
        <ChartBar size={16} class="mr-2" weight="duotone" />
        View costs
      </DropdownMenu.CheckboxItem>

      {#if chat?.active_whiteboard}
        <DropdownMenu.Item onclick={onWhiteboardOpen}>
          <Notepad size={16} class="mr-2" weight="duotone" />
          Whiteboard
        </DropdownMenu.Item>
      {/if}

      <DropdownMenu.Separator />

      <DropdownMenu.Item onclick={onArchive}>
        <Archive size={16} class="mr-2" weight="duotone" />
        {chat.archived ? 'Unarchive' : 'Archive'}
      </DropdownMenu.Item>

      {#if canDeleteChat}
        <DropdownMenu.Item
          onclick={onDelete}
          class={chat.discarded ? '' : 'text-red-600 dark:text-red-400 focus:text-red-600 dark:focus:text-red-400'}>
          {#if chat.discarded}
            <ArrowCounterClockwise size={16} class="mr-2" weight="duotone" />
            Restore
          {:else}
            <Trash size={16} class="mr-2" weight="duotone" />
            Delete
          {/if}
        </DropdownMenu.Item>
      {/if}

      {#if isSiteAdmin}
        <DropdownMenu.Separator />
        <DropdownMenu.Item onclick={onModerateAll}>
          <ShieldCheck size={16} class="mr-2" weight="duotone" />
          Moderate All Messages
        </DropdownMenu.Item>
        <DropdownMenu.CheckboxItem checked={showAllMessages} onCheckedChange={(checked) => (showAllMessages = checked)}>
          Show all messages
        </DropdownMenu.CheckboxItem>
        <DropdownMenu.CheckboxItem
          checked={showMessageTelemetry}
          onCheckedChange={(checked) => (showMessageTelemetry = checked)}>
          View telemetry
        </DropdownMenu.CheckboxItem>
        <DropdownMenu.CheckboxItem
          checked={debugMode}
          onCheckedChange={(checked) => (debugMode = checked)}
          class="text-orange-600 focus:text-orange-600">
          Debug mode
        </DropdownMenu.CheckboxItem>
      {/if}
    </DropdownMenu.Content>
  </DropdownMenu.Root>
{/if}
