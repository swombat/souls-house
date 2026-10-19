<script>
  // "What this means" for voice recognition (spec 2026-10-19). This is the
  // only place the words "voice print" appear. Backups aren't pruned, so it
  // promises nothing about how long a forgotten print survives in them
  // (Daniel, 2026-10-19, KJkkdJ).
  let { onVoicesPage = false } = $props();
</script>

<ul class="list-disc pl-5 space-y-1.5 text-sm text-muted-foreground" data-testid="voice-meaning">
  <li>
    When someone names a speaker, or confirms a guess, this Field takes that person's clear speech from the recording
    and turns it into a voice print. Each naming adds to it, so it gets better over time.
  </li>
  <li>
    Voice prints are kept, encrypted, only in this Field. The audio is processed inside souls.house and isn't sent to
    any outside service.
  </li>
  <li>
    A print is used only to suggest who's speaking in this Field's recordings, and only after it has been checked
    against recordings it wasn't learned from. A person always confirms the suggestion.
  </li>
  <li>
    Anyone in this Field can forget a voice at any time on {onVoicesPage ? 'this page' : 'the Voices page'}. A
    forgotten voice stops learning until someone chooses to remember it again.
  </li>
  <li data-testid="voice-meaning-backups">
    Backups of this Field may still hold a voice print after it's forgotten, for an indeterminate time.
  </li>
</ul>
