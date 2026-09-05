<script>
  import { Cpu } from 'phosphor-svelte';

  let { modelId = '', class: className = 'size-5' } = $props();
  const providers = {
    openai: ['openai', 'OpenAI'],
    anthropic: ['anthropic', 'Anthropic'],
    google: ['google', 'Google'],
    'x-ai': ['xai', 'xAI'],
    deepseek: ['deepseek', 'DeepSeek'],
    mistralai: ['mistral', 'Mistral'],
    'meta-llama': ['meta', 'Meta'],
    minimax: ['minimax', 'MiniMax'],
    moonshotai: ['moonshot', 'Moonshot AI'],
    qwen: ['qwen', 'Qwen'],
    'z-ai': ['zai', 'Z.ai'],
    openrouter: ['openrouter', 'OpenRouter'],
  };
  const provider = $derived(providers[modelId.split('/')[0]]);
</script>

{#if provider}
  <img
    src={`/model-providers/${provider[0]}.svg`}
    alt={`${provider[1]} logo`}
    title={provider[1]}
    class={`${className} shrink-0 dark:invert`} />
{:else}
  <span class={`${className} shrink-0`} title="Model provider" aria-label="Model provider">
    <Cpu class="size-full" />
  </span>
{/if}
