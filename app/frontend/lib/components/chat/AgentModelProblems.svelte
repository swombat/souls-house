<script>
  import { Warning } from 'phosphor-svelte';

  // One amber line per resident whose model selection has a problem, with a
  // button to fall back to the resident's default model.
  let { problems = [], savingFor = null, onusedefault } = $props();
</script>

{#each problems as { agent, selection } (agent.id)}
  <div
    role="status"
    class="mt-2 flex flex-wrap items-center gap-x-2 gap-y-1 rounded border border-amber-500/60 bg-amber-50 px-2 py-1
           text-xs text-amber-800 dark:bg-amber-950/30 dark:text-amber-300">
    <span class="min-w-0"
      ><Warning size={12} weight="bold" class="inline-block align-[-2px] mr-1" />{agent.name}: {selection.problem}.</span>
    <button
      type="button"
      class="underline underline-offset-2 hover:no-underline disabled:opacity-50"
      disabled={savingFor === agent.id}
      onclick={() => onusedefault(agent)}>
      Use resident default ({selection.default_label})
    </button>
  </div>
{/each}
