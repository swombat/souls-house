<script>
  // "What this means" for remembering a voice (spec §9). This is the only
  // place the words "voice print" appear. Backups aren't pruned, so it
  // promises nothing about how long a forgotten print survives in them
  // (Daniel, 2026-10-19, KJkkdJ).
  let { whose = "someone's voice", onVoicesPage = false } = $props();
</script>

<ul class="list-disc pl-5 space-y-1.5 text-sm text-muted-foreground" data-testid="voice-meaning">
  <li>A short sample of {whose} is turned into a voice print and kept, encrypted, only in this Field.</li>
  <li>
    It's used only to suggest who's speaking in this Field's recordings. A person always confirms the suggestion.
  </li>
  <li>Anyone in this Field can forget it at any time on {onVoicesPage ? 'this page' : 'the Voices page'}.</li>
  <li>
    Forgetting removes the voice print from this Field's active recognition database; it doesn't guarantee that
    every retained copy is erased. Recordings already sent to the voice service can't be called back. That
    service deletes what it was sent straight after processing, and its results within a day.
  </li>
  <li data-testid="voice-meaning-backups">
    Backups of this Field may still hold a voice print after it's forgotten, for an indeterminate time.
  </li>
</ul>
