<script>
  let { connection } = $props();

  const comms = $derived(connection.comms || {});
</script>

<section class="space-y-3" data-testid="whatsapp-status">
  <dl class="grid gap-x-6 gap-y-1 text-sm sm:grid-cols-[auto_1fr]">
    <dt class="text-muted-foreground">Linked as</dt>
    <dd class="min-w-0 break-words font-medium">{connection.identity || 'Unknown WhatsApp account'}</dd>
    <dt class="text-muted-foreground">Chats</dt>
    <dd>{comms.chats ?? 0} {comms.chats === 1 ? 'chat' : 'chats'} received</dd>
  </dl>
</section>
