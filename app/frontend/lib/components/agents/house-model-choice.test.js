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
    expect(screen.getByText(/Anthropic decides what it is, and can change or retire it/)).toBeTruthy();
    expect(screen.getByText(/can’t promise it will stay the same/)).toBeTruthy();
    expect(screen.getByText(/An open-weights model/)).toBeTruthy();
    expect(screen.getByText(/Served from Fireworks in the US/)).toBeTruthy();
    expect(container.textContent).not.toMatch(/reliab/i);
  });

  it('makes no cost comparison between the two', () => {
    const { container } = render(HouseModelChoice, { models, value: 'house/claude-haiku-5.5' });
    expect(container.textContent).not.toMatch(/sixth|cheaper|costs? (the house )?less|lasts? (many )?(more|longer)|allowance faster/i);
    expect(screen.getByText(/Both come out of the same monthly allowance/)).toBeTruthy();
  });

  it('points people with their own key at the full list', () => {
    render(HouseModelChoice, { models, value: 'house/claude-haiku-5.5' });
    expect(screen.queryByRole('link')).toBeNull();
    expect(screen.getByText(/You can choose any model below/)).toBeTruthy();
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
