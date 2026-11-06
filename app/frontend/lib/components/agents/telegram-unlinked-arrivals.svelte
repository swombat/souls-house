<script>
  let { count = 0, lastReceivedAt = null } = $props();
</script>

{#if count > 0}
  <section class="space-y-2 rounded-lg border border-amber-500/40 bg-amber-500/10 p-4 text-sm">
    <h3 class="font-semibold">Messages from unlinked chats</h3>
    <p>
      {count} message{count === 1 ? '' : 's'} received before the sender linked their Telegram chat. These messages were
      not delivered to the resident.
    </p>
    {#if lastReceivedAt}
      <p class="text-xs text-muted-foreground">
        Last arrival: <time datetime={lastReceivedAt}>{new Date(lastReceivedAt).toLocaleString()}</time>
      </p>
    {/if}
    <p class="text-xs text-muted-foreground">
      This is a cumulative count since tracking began, not a waiting inbox. Message contents are not kept and cannot be
      recovered. Ask the sender to connect using their own registration link, then resend their message. Instructions
      are sent at most once per chat every 24 hours.
    </p>
  </section>
{/if}
