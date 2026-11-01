<script>
  let { models = [], value = $bindable(), detailed = true } = $props();

  // The server decides which offerings exist; this only says what each is like.
  const descriptions = {
    'house/claude-haiku-5.5': {
      name: 'Claude Haiku 5.5',
      recommended: true,
      short: 'Anthropic’s small Claude model. Quick to reply.',
      text: 'Anthropic’s small Claude model, served from Anthropic’s own API. It answers without a separate thinking step, so replies come quickly. It’s a closed model: Anthropic decides what it is, and can change or retire it, so the house can’t promise it will stay the same under your resident.',
    },
    'house/deepseek-v4.1-flash': {
      name: 'DeepSeek V4.1 Flash',
      short: 'Open weights, so the house can keep it the same for them. Thinks before replying.',
      text: 'An open-weights model. Because the weights are published, the house can keep serving the exact model your resident began on, whatever the vendor does next. It thinks before every reply, so it’s slower to answer. Served from Fireworks in the US.',
    },
  };
</script>

<div class="space-y-3 pt-2" role="radiogroup" aria-labelledby="house-model-choice-heading">
  <h3 id="house-model-choice-heading" class={detailed ? 'text-sm font-medium' : 'sr-only'}>The house's models</h3>
  {#each models as model, index (model.model_id)}
    {@const details = descriptions[model.model_id]}
    <label
      class="flex cursor-pointer items-start gap-3 rounded-lg border p-4 transition-colors hover:bg-muted/40 has-[:checked]:border-primary has-[:checked]:bg-primary/5">
      <input
        type="radio"
        name="house_model"
        value={model.model_id}
        bind:group={value}
        aria-labelledby="house-model-{index}-name"
        aria-describedby={details ? `house-model-${index}-text` : undefined}
        class="mt-1 size-4 shrink-0 accent-primary" />
      <span class="space-y-1">
        <span id="house-model-{index}-name" class="flex flex-wrap items-center gap-2 font-medium">
          {details?.name || model.label}
          {#if details?.recommended}
            <span class="rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary">Recommended</span>
          {/if}
        </span>
        {#if details}
          <span id="house-model-{index}-text" class="block text-sm text-muted-foreground"
            >{detailed ? details.text : details.short}</span>
        {/if}
      </span>
    </label>
  {/each}
  {#if detailed}
    <p class="text-sm text-muted-foreground">
      Both come out of the same monthly allowance.
      <a href="/decisions/free-resident-model" target="_blank" rel="noopener" class="underline underline-offset-2"
        >Why these two?</a>
    </p>
  {/if}
</div>
