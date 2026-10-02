<script>
  import { useForm } from '@inertiajs/svelte';
  import AgentIntegrationsPanel from '../app/frontend/lib/components/agents/AgentIntegrationsPanel.svelte';

  let { agent, telegramDeepLink = null, telegramSubscriberCount = 0 } = $props();

  const form = useForm({
    agent: {
      telegram_bot_username: agent.telegram_bot_username || '',
      telegram_bot_token: '',
    },
  });
</script>

<form onsubmit={(event) => event.preventDefault()}>
  <AgentIntegrationsPanel
    {form}
    {agent}
    account={{ id: 'integration-test-account' }}
    {telegramDeepLink}
    {telegramSubscriberCount}
    onsendTestNotification={() => {}}
    onregisterWebhook={() => {}} />
</form>
