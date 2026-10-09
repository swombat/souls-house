import { render, screen } from '@testing-library/svelte';
import { writable } from 'svelte/store';
import { describe, expect, it } from 'vitest';
import RuntimeStep from './runtime-step.svelte';

const grouped_models = {
  'Top Models': [{ model_id: 'openai/gpt-6-astra', label: 'GPT-6 Astra' }],
  'On the house': [
    { model_id: 'house/claude-haiku-5.5', label: 'Claude Haiku 5.5 · On the house' },
    { model_id: 'house/deepseek-v4.1-flash', label: 'DeepSeek V4.1 Flash · On the house' },
  ],
};
const form = () => writable({ agent: { scheduled_wakes_enabled: true } });

describe('Runtime step', () => {
  it('puts the two house models first when the house is offering funding', () => {
    render(RuntimeStep, { form: form(), grouped_models, houseOffered: true, selectedModel: 'house/claude-haiku-5.5' });
    expect(screen.getByRole('radio', { name: /Claude Haiku 5.5/ })).toBeChecked();
    expect(screen.getByRole('radio', { name: /DeepSeek V4.1 Flash/ })).toBeTruthy();
    expect(screen.getByText('Or any model')).toBeTruthy();
  });

  it('shows only the full list when the house is not offering funding', () => {
    render(RuntimeStep, { form: form(), grouped_models, houseOffered: false, selectedModel: 'openai/gpt-6-astra' });
    expect(screen.queryByRole('radio')).toBeNull();
    expect(screen.getByText('Model')).toBeTruthy();
  });
});
