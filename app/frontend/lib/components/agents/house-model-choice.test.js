import { fireEvent, render, screen } from '@testing-library/svelte';
import { describe, expect, it } from 'vitest';
import HouseModelChoice from './house-model-choice.svelte';

const models = [
  { model_id: 'house/claude-haiku-5.5', label: 'Claude Haiku 5.5 · On the house' },
  { model_id: 'house/deepseek-v4.1-flash', label: 'DeepSeek V4.1 Flash · On the house' },
];

describe('House model choice', () => {
  it('offers both house models with Haiku preselected and recommended', () => {
    render(HouseModelChoice, { models, value: 'house/claude-haiku-5.5' });
    const haiku = screen.getByRole('radio', { name: /Claude Haiku 5.5/ });
    const deepseek = screen.getByRole('radio', { name: /DeepSeek V4.1 Flash/ });
    expect(haiku).toBeChecked();
    expect(deepseek).not.toBeChecked();
    expect(screen.getByText('Recommended')).toBeTruthy();
  });

  it('explains the trade-off without calling either model unreliable', () => {
    const { container } = render(HouseModelChoice, { models, value: 'house/claude-haiku-5.5' });
    expect(screen.getByText(/about a sixth as much per reply/)).toBeTruthy();
    expect(screen.getByText(/Anthropic could change or withdraw it/)).toBeTruthy();
    expect(screen.getByText(/Open weights/)).toBeTruthy();
    expect(screen.getByText(/Served from Fireworks in the US/)).toBeTruthy();
    expect(container.textContent).not.toMatch(/reliab/i);
  });

  it('links to the decision and points people with their own key at the full list', () => {
    render(HouseModelChoice, { models, value: 'house/claude-haiku-5.5' });
    expect(screen.getByRole('link', { name: /how we chose/ })).toHaveAttribute(
      'href',
      '/decisions/free-resident-model'
    );
    expect(screen.getByText(/You can choose any model below instead/)).toBeTruthy();
  });

  it('switches to DeepSeek when chosen', async () => {
    render(HouseModelChoice, { models, value: 'house/claude-haiku-5.5' });
    const deepseek = screen.getByRole('radio', { name: /DeepSeek V4.1 Flash/ });
    await fireEvent.click(deepseek);
    expect(deepseek).toBeChecked();
    expect(screen.getByRole('radio', { name: /Claude Haiku 5.5/ })).not.toBeChecked();
  });

  it('only shows offerings the server lists', () => {
    render(HouseModelChoice, { models: [models[1]], value: 'house/deepseek-v4.1-flash' });
    expect(screen.queryByRole('radio', { name: /Claude Haiku/ })).toBeNull();
  });
});
