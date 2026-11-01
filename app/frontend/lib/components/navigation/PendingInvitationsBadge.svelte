<script>
  // An envelope when any account has invited you and is waiting for you to
  // accept. No number: whether there is one invitation or three, the thing to
  // know is that the door is open (Daniel, 2026-10-27). Black like the
  // expired-subscriptions badge; it is not unread mail.
  import { EnvelopeSimple } from 'phosphor-svelte';

  let { count = 0 } = $props();
</script>

{#if count > 0}
  <span
    class="inline-flex size-5 shrink-0 items-center justify-center rounded-full bg-neutral-950 text-white dark:bg-white dark:text-neutral-950"
    title="Pending invitations"
    aria-label="Pending invitations"
    data-testid="pending-invitations-badge">
    <EnvelopeSimple class="size-3.5" weight="bold" aria-hidden="true" />
  </span>
{/if}
