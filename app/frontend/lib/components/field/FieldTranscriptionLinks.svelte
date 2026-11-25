<script>
  import { Link } from '@inertiajs/svelte';

  // The Field's way to the account settings that shape its transcripts:
  // who is speaking (Speakers) and how words are spelled (Glossary).
  let { accountId } = $props();
</script>

<p class="mt-1 text-sm text-muted-foreground" data-testid="field-transcription-links">
  Transcription:
  <Link href={`/accounts/${accountId}/field/voices`} class="underline hover:text-foreground">Speakers</Link>
  ·
  <Link href={`/accounts/${accountId}/glossary`} class="underline hover:text-foreground">Glossary</Link>
</p>
