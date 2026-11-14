<script>
  // Test harness for ReaderMode: a stateful child and a sibling to tab into.
  import ReaderMode from './ReaderMode.svelte';

  let open = $state(false);
  let draft = $state('');
</script>

<button data-testid="outside" onclick={() => (open = true)}>Open</button>
<ReaderMode {open} title="A transcript" onClose={() => (open = false)}>
  <input data-testid="draft" bind:value={draft} />
</ReaderMode>
