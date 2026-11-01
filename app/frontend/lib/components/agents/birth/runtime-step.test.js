import { fireEvent, render, screen } from '@testing-library/svelte';
import { beforeAll, describe, expect, it } from 'vitest';
import RuntimeStep from './runtime-step.svelte';

const grouped_models = {
  'Top Models': [
    { model_id: 'anthropic/claude-opus-5.5', label: 'Claude Opus 5.5', key_provider: 'anthropic' },
    { model_id: 'deepseek/deepseek-v4', label: 'DeepSeek V4', key_provider: 'openrouter' },
  ],
  'On the house': [
    { model_id: 'house/claude-haiku-5.5', label: 'Claude Haiku 5.5 · On the house', key_provider: null },
    { model_id: 'house/deepseek-v4.1-flash', label: 'DeepSeek V4.1 Flash · On the house', key_provider: null },
  ],
};

// jsdom has no Web Animations; Svelte's slide transition needs element.animate.
beforeAll(() => {
  Element.prototype.animate ??= function () {
    const animation = { cancel() {}, finish() {}, onfinish: null };
    queueMicrotask(() => animation.onfinish?.());
    return animation;
  };
});

describe('Runtime step', () => {
  it('asks about keys first and shows nothing else until a path is chosen', () => {
    render(RuntimeStep, { grouped_models, houseOffered: true, selectedModel: 'house/claude-haiku-5.5' });
    expect(screen.getByRole('radio', { name: /I don't have my own keys/ })).toBeTruthy();
    expect(screen.getByRole('radio', { name: /I have my own keys/ })).toBeTruthy();
    expect(screen.queryByText(/On the house · \$10 per month/)).toBeNull();
    expect(screen.queryByTestId('own-keys-path')).toBeNull();
    expect(screen.queryByText(/heartbeat/i)).toBeNull();
  });

  it('offers the two house models, with the allowance, on the no-keys path', async () => {
    render(RuntimeStep, { grouped_models, houseOffered: true, selectedModel: 'house/claude-haiku-5.5' });
    await fireEvent.click(screen.getByRole('radio', { name: /I don't have my own keys/ }));
    expect(screen.getByRole('radio', { name: /Claude Haiku 5.5/ })).toBeChecked();
    expect(screen.getByRole('radio', { name: /DeepSeek V4.1 Flash/ })).toBeTruthy();
    expect(screen.getByText(/On the house · \$10 per month/)).toBeTruthy();
    expect(screen.queryByRole('region', { name: 'House inference allowance' })).toBeNull();

    await fireEvent.click(screen.getByRole('button', { name: 'Show more' }));
    expect(screen.getByRole('region', { name: 'House inference allowance' })).toBeTruthy();
  });

  it('asks for the key the chosen model needs on the own-keys path', async () => {
    render(RuntimeStep, {
      grouped_models,
      houseOffered: true,
      selectedModel: 'house/claude-haiku-5.5',
      canManageKeys: true,
    });
    await fireEvent.click(screen.getByRole('radio', { name: /I have my own keys/ }));
    expect(screen.getByLabelText('Anthropic API key')).toBeTruthy();
    expect(screen.queryByText(/On the house · \$10 per month/)).toBeNull();
  });

  it('says so when the key is already saved', async () => {
    render(RuntimeStep, {
      grouped_models,
      houseOffered: true,
      selectedModel: 'house/claude-haiku-5.5',
      canManageKeys: true,
      keysConfigured: { anthropic: true },
    });
    await fireEvent.click(screen.getByRole('radio', { name: /I have my own keys/ }));
    expect(screen.getByText(/Anthropic key is already saved/)).toBeTruthy();
    expect(screen.queryByLabelText('Anthropic API key')).toBeNull();
  });

  it('goes straight to the own-keys path when the house is not offering funding', () => {
    render(RuntimeStep, {
      grouped_models,
      houseOffered: false,
      selectedModel: 'deepseek/deepseek-v4',
      canManageKeys: true,
    });
    expect(screen.queryByRole('radio', { name: /I don't have my own keys/ })).toBeNull();
    expect(screen.getByLabelText('OpenRouter API key')).toBeTruthy();
  });
});

test('in an account that pays per resident, the house path says the plan pays for it', async () => {
  render(RuntimeStep, {
    grouped_models: { 'On the house': [{ model_id: 'house/claude-haiku-5.5', label: 'Claude Haiku 5.5' }] },
    houseOffered: true,
    selectedModel: 'house/claude-haiku-5.5',
    keyPath: 'house',
    planAllowance: [10, 45],
  });
  expect(screen.getByText("The plan includes $10 to $45 a month of the house's models.")).toBeInTheDocument();
  expect(screen.getByTestId('house-path-terms')).toHaveTextContent('Included in the plan.');
  expect(screen.queryByText(/One funded resident per person/)).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Show more' })).not.toBeInTheDocument();
});
