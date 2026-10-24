<script>
  import QRCode from 'qrcode';
  import { formatCountdown } from '$lib/telegram-connection';

  // The QR half of the owner's WhatsApp pairing: the current code as an
  // image, how to scan it, and how long it has left. The parent polls.
  let { qr = null, phase, secondsLeft = 0 } = $props();

  let qrImage = $state(null);

  $effect(() => {
    const code = qr?.code;
    if (!code) {
      qrImage = null;
      return;
    }
    let current = true;
    QRCode.toDataURL(code, { margin: 1, width: 240, errorCorrectionLevel: 'M' })
      .then((url) => current && (qrImage = url))
      .catch(() => current && (qrImage = null));
    return () => (current = false);
  });
</script>

{#if ['scan', 'rotating', 'expired'].includes(phase)}
  <div class="flex flex-col gap-4 sm:flex-row sm:items-start">
    <div class="w-fit shrink-0 rounded-lg bg-white p-2">
      {#if qrImage}
        <img
          src={qrImage}
          alt="WhatsApp pairing QR code"
          width="200"
          height="200"
          data-issued-at={qr.issued_at}
          class={`size-[200px] ${phase === 'scan' ? '' : 'opacity-30'}`} />
      {:else}
        <div class="size-[200px]"></div>
      {/if}
    </div>
    <div class="min-w-0 space-y-2 text-sm">
      <p class="font-medium">Scan this code with WhatsApp on your phone.</p>
      <ol class="list-decimal space-y-1 pl-5 text-muted-foreground">
        <li>Open WhatsApp and go to Settings, then Linked devices.</li>
        <li>Tap Link a device.</li>
        <li>Point the camera at this code.</li>
      </ol>
      <p class={phase === 'expired' ? 'text-destructive' : 'text-muted-foreground'} data-testid="whatsapp-qr-countdown">
        {#if phase === 'scan'}
          This code expires in {formatCountdown(secondsLeft)}. A new one appears by itself.
        {:else if phase === 'rotating'}
          This code expired. Waiting for a new one.
        {:else}
          Pairing timed out: WhatsApp stopped sending codes. Restart pairing for a new one.
        {/if}
      </p>
    </div>
  </div>
{:else if phase === 'waiting'}
  <p class="text-sm text-muted-foreground">Waiting for a pairing code from WhatsApp.</p>
{/if}
