<script>
  import AgentPickerDialog from '$lib/components/chat/AgentPickerDialog.svelte';
  import ManageResidentsDialog from '$lib/components/chat/ManageResidentsDialog.svelte';
  import WhiteboardDrawer from '$lib/components/chat/WhiteboardDrawer.svelte';
  import EditMessageDrawer from '$lib/components/chat/EditMessageDrawer.svelte';
  import ImageLightbox from '$lib/components/chat/ImageLightbox.svelte';
  import ToastNotification from '$lib/components/chat/ToastNotification.svelte';

  let {
    chat,
    account,
    agents = [],
    availableAgents = [],
    addableAgents = [],
    shikiTheme,
    agentIsResponding = false,
    whiteboardOpen = $bindable(false),
    editDrawerOpen = $bindable(false),
    editingMessageId = null,
    editingContent = '',
    errorMessage = null,
    successMessage = null,
    assignAgentOpen = $bindable(false),
    assigningAgent = false,
    manageResidentsOpen = $bindable(false),
    manageResidentsProcessing = false,
    lightboxOpen = $bindable(false),
    lightboxImage = null,
    onEditSaved = () => {},
    onEditClosed = () => {},
    onError = () => {},
    onAssignAgent = () => {},
    onSaveResidents = () => {},
  } = $props();
</script>

{#if chat?.active_whiteboard}
  <WhiteboardDrawer
    bind:open={whiteboardOpen}
    whiteboard={chat.active_whiteboard}
    accountId={account.id}
    {agentIsResponding}
    {shikiTheme} />
{/if}

<EditMessageDrawer
  bind:open={editDrawerOpen}
  messageId={editingMessageId}
  initialContent={editingContent}
  onsaved={onEditSaved}
  onclosed={onEditClosed}
  onerror={onError} />

<ToastNotification message={errorMessage} variant="error" />
<ToastNotification message={successMessage} variant="success" />

<AgentPickerDialog
  bind:open={assignAgentOpen}
  agents={availableAgents}
  title="Assign to Resident"
  description="Select a resident to take over this conversation. The resident will be informed that previous messages were with a model that had no identity or memories."
  confirmLabel="Assign"
  confirmingLabel="Assigning..."
  processing={assigningAgent}
  onconfirm={onAssignAgent} />

<ManageResidentsDialog
  bind:open={manageResidentsOpen}
  {agents}
  {addableAgents}
  processing={manageResidentsProcessing}
  onsave={onSaveResidents} />

<ImageLightbox bind:open={lightboxOpen} file={lightboxImage} />
