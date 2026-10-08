<script>
  // "What this means" for remembering a voice (spec §9). This is the only
  // place the words "voice print" appear. On the transcript page the backup
  // period isn't known, so it links to the Voices page (voicesUrl); on the
  // Voices page it states the number of days (backupDays), or leaves the
  // sentence out when there is no number.
  import { Link } from '@inertiajs/svelte';

  let { whose = "someone's voice", backupDays = null, voicesUrl = null, onVoicesPage = false } = $props();
</script>

<ul class="list-disc pl-5 space-y-1.5 text-sm text-muted-foreground" data-testid="voice-meaning">
  <li>A short sample of {whose} is turned into a voice print and kept, encrypted, only in this Field.</li>
  <li>
    It's used only to suggest who's speaking in this Field's recordings. A person always confirms the suggestion.
  </li>
  <li>Anyone in this Field can forget it at any time on {onVoicesPage ? 'this page' : 'the Voices page'}.</li>
  <li>
    Forgetting deletes the voice print. Recordings already sent to the voice service can't be called back. That
    service deletes what it was sent straight after processing, and its results within a day.
  </li>
  {#if backupDays != null}
    <li data-testid="voice-meaning-backups">
      Backups made before you forget a voice keep it until they expire, after {backupDays}
      {backupDays === 1 ? 'day' : 'days'}.
    </li>
  {:else if voicesUrl}
    <li>
      Backups made before a forget keep the voice print until they expire.
      <Link href={voicesUrl} class="underline underline-offset-2 hover:text-foreground">The Voices page</Link> says how
      long that is.
    </li>
  {/if}
</ul>
