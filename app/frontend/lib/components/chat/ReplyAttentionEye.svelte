<script>
  import { page } from '@inertiajs/svelte';
  import { Eye } from 'phosphor-svelte';

  let { chatId } = $props();
</script>

{#if $page.props?.reply_attention?.chats?.[chatId] > 0}
  <span
    class="inline-flex text-red-600 dark:text-red-400 shrink-0 align-middle"
    role="img"
    aria-label="Your response is requested"
    title="Your response is requested">
    <Eye size={16} weight="fill" />
  </span>
{/if}
