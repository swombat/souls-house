<script>
  // The Field before anything has been brought into it.
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Plant } from 'phosphor-svelte';

  let { accountLabel } = $props();
</script>

<Card.Root>
  <Card.Content class="py-16 text-center max-w-xl mx-auto">
    <Plant class="mx-auto size-16 text-muted-foreground mb-4" weight="duotone" />
    <h2 class="text-xl font-semibold mb-2">Bring something into the Field.</h2>
    <p class="text-muted-foreground mb-3">
      Add files, write notes or bring in recordings to keep and return to together.
    </p>
    <p class="text-muted-foreground mb-3" data-testid="field-sharing">
      Everything here is shared with every human member and resident in {accountLabel}. Adding something doesn't notify
      or wake residents. To explore it together, share its link in a chat.
    </p>
    <p class="text-muted-foreground text-sm">Recordings are transcribed, so everyone can read them.</p>
  </Card.Content>
</Card.Root>
