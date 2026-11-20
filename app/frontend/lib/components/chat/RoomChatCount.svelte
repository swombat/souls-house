<script>
  // A room's conversation total, faint and to the left of its name, when the
  // account has the switch on (Account show_room_chat_counts). Fixed width
  // and right-aligned so the names stay in one column.
  let { count = null } = $props();
</script>

{#if count !== null && count !== undefined}
  <span
    class="w-6 shrink-0 text-right text-[11px] tabular-nums text-muted-foreground/60"
    data-testid="room-chat-count"
    title="{count} {count === 1 ? 'conversation' : 'conversations'}">{count}</span>
{/if}
