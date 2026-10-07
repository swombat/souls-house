import { fireEvent, render, screen } from '@testing-library/svelte';
import { describe, expect, it } from 'vitest';
import AgentSubagentsPanel from './AgentSubagentsPanel.svelte';

const catalog = [
  {
    key: 'anthropic:claude-sonnet-5',
    provider: 'anthropic',
    provider_label: 'Anthropic',
    source: 'API key',
    model: 'claude-sonnet-5',
    label: 'Claude Sonnet 5',
  },
  {
    key: 'anthropic:claude-haiku-5',
    provider: 'anthropic',
    provider_label: 'Anthropic',
    source: 'Claude subscription',
    model: 'claude-haiku-5',
    label: 'Claude Haiku 5',
  },
  {
    key: 'openai:gpt-6',
    provider: 'openai',
    provider_label: 'OpenAI',
    source: 'API key',
    model: 'gpt-6',
    label: 'GPT-6',
  },
];

describe('resident sub-agents', () => {
  it('hides the allowed-models list while sub-agents are disabled', () => {
    render(AgentSubagentsPanel, { enabled: false, models: [], catalog });
    expect(screen.queryByText('Allowed sub-agent models')).not.toBeInTheDocument();
  });

  it('reveals the allowed-models list once enabled', async () => {
    render(AgentSubagentsPanel, { enabled: false, models: [], catalog });
    await fireEvent.click(screen.getByRole('checkbox', { name: 'Allow this resident to use sub-agents' }));
    expect(screen.getByText('Allowed sub-agent models')).toBeInTheDocument();
    expect(screen.getByText(/No models allowed yet/)).toBeInTheDocument();
  });

  it('moves a catalogue entry into the allowed list when added', async () => {
    render(AgentSubagentsPanel, { enabled: true, models: [], catalog });
    await fireEvent.click(screen.getAllByRole('button', { name: 'Add' })[0]);
    expect(screen.queryByText(/No models allowed yet/)).not.toBeInTheDocument();
    expect(screen.getByText('Claude Sonnet 5')).toBeInTheDocument();
    expect(screen.getByText('Anthropic · API key')).toBeInTheDocument();
  });

  it('moves an allowed model back to the catalogue when removed', async () => {
    render(AgentSubagentsPanel, { enabled: true, models: ['anthropic:claude-sonnet-5'], catalog });
    expect(screen.getByRole('button', { name: 'Remove' })).toBeInTheDocument();
    await fireEvent.click(screen.getByRole('button', { name: 'Remove' }));
    expect(screen.getByText(/No models allowed yet/)).toBeInTheDocument();
    expect(screen.getAllByRole('button', { name: 'Add' })).toHaveLength(3);
  });

  it('filters the catalogue by label, model, or provider text', async () => {
    render(AgentSubagentsPanel, { enabled: true, models: [], catalog });
    await fireEvent.input(screen.getByPlaceholderText('Filter by model, provider, or source'), {
      target: { value: 'gpt' },
    });
    expect(screen.getByText('GPT-6')).toBeInTheDocument();
    expect(screen.queryByText('Claude Sonnet 5')).not.toBeInTheDocument();
    expect(screen.queryByText('Claude Haiku 5')).not.toBeInTheDocument();
  });

  it('marks an allowed key that is no longer in the catalogue', () => {
    render(AgentSubagentsPanel, { enabled: true, models: ['anthropic:retired-model'], catalog });
    expect(screen.getByText('No longer available')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Remove' })).toBeInTheDocument();
  });

  it('shows the empty-catalogue reason instead of the add control when there is nothing to add', () => {
    render(AgentSubagentsPanel, {
      enabled: true,
      models: [],
      catalog: [],
      emptyReason: 'Add an API key or connect a subscription to choose sub-agent models.',
    });
    expect(
      screen.getByText('Add an API key or connect a subscription to choose sub-agent models.')
    ).toBeInTheDocument();
    expect(screen.queryByPlaceholderText('Filter by model, provider, or source')).not.toBeInTheDocument();
  });

  it('adds a custom model by ID when its provider is in the provider list', async () => {
    const providers = [{ provider: 'anthropic', provider_label: 'Anthropic', source: 'API key' }];
    render(AgentSubagentsPanel, { enabled: true, models: [], catalog: [], providers, emptyReason: 'none' });
    await fireEvent.change(screen.getByLabelText('Provider'), { target: { value: 'anthropic' } });
    await fireEvent.input(screen.getByPlaceholderText('Model ID'), { target: { value: 'claude-opus-7' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Add' }));
    expect(screen.getByText('claude-opus-7')).toBeInTheDocument();
    expect(screen.getByText('Anthropic · API key · custom ID')).toBeInTheDocument();
  });

  it('rejects empty, whitespace, and duplicate custom model IDs', async () => {
    const providers = [{ provider: 'anthropic', provider_label: 'Anthropic', source: 'API key' }];
    render(AgentSubagentsPanel, { enabled: true, models: ['anthropic:claude-sonnet-5'], catalog, providers });
    const providerSelect = screen.getByLabelText('Provider');
    const idInput = screen.getByPlaceholderText('Model ID');
    const addButton = screen.getAllByRole('button', { name: 'Add' }).at(-1);

    await fireEvent.click(addButton);
    expect(screen.getByText('Choose a provider.')).toBeInTheDocument();

    await fireEvent.change(providerSelect, { target: { value: 'anthropic' } });
    await fireEvent.click(addButton);
    expect(screen.getByText('Enter a model ID.')).toBeInTheDocument();

    await fireEvent.input(idInput, { target: { value: 'has space' } });
    await fireEvent.click(addButton);
    expect(screen.getByText('Model ID cannot contain spaces.')).toBeInTheDocument();

    await fireEvent.input(idInput, { target: { value: 'claude-sonnet-5' } });
    await fireEvent.click(addButton);
    expect(screen.getByText('That model is already allowed.')).toBeInTheDocument();
  });

  it('displays a custom allowed entry distinctly from an unavailable one', () => {
    const providers = [{ provider: 'anthropic', provider_label: 'Anthropic', source: 'API key' }];
    render(AgentSubagentsPanel, {
      enabled: true,
      models: ['anthropic:claude-custom-9', 'retired:ghost-model'],
      catalog,
      providers,
    });
    expect(screen.getByText('claude-custom-9')).toBeInTheDocument();
    expect(screen.getByText('Anthropic · API key · custom ID')).toBeInTheDocument();
    expect(screen.getByText('No longer available')).toBeInTheDocument();
  });
  it('shows server validation errors on the tab', () => {
    render(AgentSubagentsPanel, {
      enabled: true,
      models: ['openrouter:bad?'],
      catalog,
      serverErrors: ['contains invalid entries: openrouter:bad?'],
    });
    expect(screen.getByRole('alert')).toHaveTextContent('Sub-agent models contains invalid entries: openrouter:bad?');
  });

  it('rejects custom IDs the server would refuse', async () => {
    const providers = [{ provider: 'openrouter', provider_label: 'OpenRouter', source: 'API key' }];
    render(AgentSubagentsPanel, { enabled: true, models: [], catalog, providers });
    await fireEvent.change(screen.getByLabelText('Provider'), { target: { value: 'openrouter' } });
    await fireEvent.input(screen.getByPlaceholderText('Model ID'), { target: { value: 'bad?' } });
    const addButtons = screen.getAllByRole('button', { name: 'Add' });
    await fireEvent.click(addButtons[addButtons.length - 1]);
    expect(screen.getByText(/Model IDs may use letters, digits/)).toBeInTheDocument();
  });

  it('stops adding once fifty models are allowed', () => {
    const models = Array.from({ length: 50 }, (_, index) => `openrouter:model-${index}`);
    render(AgentSubagentsPanel, { enabled: true, models, catalog });
    for (const button of screen.getAllByRole('button', { name: 'Add' })) {
      expect(button).toBeDisabled();
    }
  });
});
