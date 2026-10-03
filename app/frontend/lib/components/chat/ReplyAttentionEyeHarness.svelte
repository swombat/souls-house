<script>
  import ReplyAttentionEye from './ReplyAttentionEye.svelte';
  let { chat } = $props();
</script>

<ReplyAttentionEye chatId={chat.id} accountId="account" />
