<script>
  import NewChatForm from '$lib/components/chat/NewChatForm.svelte';

  let {
    user = null,
    account,
    chats = [],
    agents = [],
    show_usage_in_chat = false,
    file_upload_config = null,
    voice_mode = { offered: false, available: false, reason: null },
  } = $props();
</script>

{#key JSON.stringify([user?.id, account.id])}
  <NewChatForm
    userId={user?.id}
    {account}
    {chats}
    {agents}
    {show_usage_in_chat}
    {file_upload_config}
    voiceMode={voice_mode} />
{/key}
