import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import { get, writable } from 'svelte/store';
import AgentConversationModels from './AgentConversationModels.svelte';

afterEach(cleanup);

const groupedModels = {
  'Top Models': [
    { model_id: 'openai/gpt-6-astra', label: 'GPT-6 Astra' },
    { model_id: 'anthropic/claude-opus-5.5', label: 'Claude Opus 5.5' },
  ],
  OpenAI: [
    { model_id: 'openai/gpt-6-astra', label: 'GPT-6 Astra' },
    { model_id: 'openai/gpt-6.1-sol', label: 'GPT-6.1 Sol' },
    { model_id: 'openai/gpt-6-luna', label: 'GPT-6 Luna' },
  ],
  'On the house': [{ model_id: 'house/deepseek-v4.1-flash', label: 'DeepSeek V4.1 Flash · On the house' }],
};

const formFor = (agent) => writable({ agent, errors: {} });

test('offers same-provider models once each, without the default or house models', () => {
  const form = formFor({
    name: 'Lume',
    switchable_model_ids: ['openai/gpt-6-astra'],
    resident_may_switch_model: false,
  });
  render(AgentConversationModels, { form, groupedModels, defaultModelId: 'openai/gpt-6.1-sol', agentName: 'Lume' });
  const boxes = screen.getAllByRole('checkbox');
  expect(boxes.map((box) => box.closest('label').textContent.trim())).toEqual(['GPT-6 Astra', 'GPT-6 Luna']);
  expect(screen.getByRole('checkbox', { name: 'GPT-6 Astra' })).toBeChecked();
  expect(screen.getByText(/GPT-6.1 Sol stays the default/)).toBeInTheDocument();
  expect(screen.getByText('Let Lume change its own model in a conversation')).toBeInTheDocument();
});

test('checking and unchecking updates switchable_model_ids', async () => {
  const form = formFor({ name: 'Lume', switchable_model_ids: [], resident_may_switch_model: false });
  render(AgentConversationModels, { form, groupedModels, defaultModelId: 'openai/gpt-6.1-sol', agentName: 'Lume' });
  await fireEvent.click(screen.getByRole('checkbox', { name: 'GPT-6 Luna' }));
  expect(get(form).agent.switchable_model_ids).toEqual(['openai/gpt-6-luna']);
  await fireEvent.click(screen.getByRole('checkbox', { name: 'GPT-6 Luna' }));
  expect(get(form).agent.switchable_model_ids).toEqual([]);
});

test('a house default offers no conversation models', () => {
  const form = formFor({ name: 'Lume', switchable_model_ids: [], resident_may_switch_model: false });
  render(AgentConversationModels, {
    form,
    groupedModels,
    defaultModelId: 'house/deepseek-v4.1-flash',
    agentName: 'Lume',
  });
  expect(screen.queryAllByRole('checkbox')).toHaveLength(0);
  expect(screen.getByText(/not available while the default is a house model/)).toBeInTheDocument();
});

test('listed models from another provider are shown so they can be removed, with server errors', () => {
  const form = writable({
    agent: { name: 'Lume', switchable_model_ids: ['anthropic/claude-opus-5.5'], resident_may_switch_model: true },
    errors: { switchable_model_ids: 'Claude Opus 5.5 is from a different provider than the default model' },
  });
  render(AgentConversationModels, { form, groupedModels, defaultModelId: 'openai/gpt-6.1-sol', agentName: 'Lume' });
  expect(screen.getByText('Claude Opus 5.5')).toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Remove' })).toBeInTheDocument();
  expect(screen.getByText('Claude Opus 5.5 is from a different provider than the default model')).toBeInTheDocument();
});
