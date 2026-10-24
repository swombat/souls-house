<script>
  // Under a resident's message: whom it handed off to (an @Name tag or
  // recipient_agent_ids), and whether the message has reached them. Delivered
  // means a run of theirs read it, not that they replied.
  let { receipts = [] } = $props();

  const LABELS = { queued: 'queued', held: 'held', delivered: 'delivered', blocked: 'blocked' };
  const TITLES = {
    queued: 'Their run has been asked for and has not read the conversation yet.',
    held: 'They were already responding here; this waits for that run to finish.',
    delivered: 'A run of theirs has read this message. Whether to reply is theirs.',
    blocked: 'This message will not wake them.',
  };

  function label(receipt) {
    const state = LABELS[receipt.state] || receipt.state;
    return receipt.state === 'blocked' && receipt.reason ? `${state}: ${receipt.reason}` : state;
  }
</script>

{#if receipts.length > 0}
  <div
    class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground"
    data-testid="handoff-receipts">
    {#each receipts as receipt (receipt.recipient_id)}
      <span
        data-testid="handoff-receipt"
        data-state={receipt.state}
        title={TITLES[receipt.state] || ''}
        class:text-amber-700={receipt.state === 'blocked'}
        class:dark:text-amber-400={receipt.state === 'blocked'}>
        to {receipt.recipient_name} · {label(receipt)}
      </span>
    {/each}
  </div>
{/if}
