import { describe, expect, it } from 'vitest';
import {
  filterGroupedModels,
  findModelLabel,
  firstModelId,
  groupModelsByProvider,
  modelSupportsThinking,
} from './agent-models';

describe('agent model helpers', () => {
  const groupedModels = {
    OpenAI: [
      { model_id: 'openai/gpt-5', label: 'GPT-5', supports_thinking: true },
      { model_id: 'openai/gpt-5-mini', label: 'GPT-5 Mini', supports_thinking: false },
    ],
    Anthropic: [{ model_id: 'anthropic/claude-opus', label: 'Claude Opus', supports_thinking: true }],
  };

  it('finds labels and thinking support across grouped models', () => {
    expect(findModelLabel(groupedModels, 'openai/gpt-5')).toBe('GPT-5');
    expect(findModelLabel(groupedModels, 'missing/model')).toBe('missing/model');
    expect(modelSupportsThinking(groupedModels, 'anthropic/claude-opus')).toBe(true);
    expect(modelSupportsThinking(groupedModels, 'openai/gpt-5-mini')).toBe(false);
    expect(modelSupportsThinking(groupedModels, 'missing/model')).toBe(false);
  });

  it('uses the first grouped model id with a fallback', () => {
    expect(firstModelId(groupedModels)).toBe('openai/gpt-5');
    expect(firstModelId({}, 'openrouter/auto')).toBe('openrouter/auto');
  });

  it('groups flat models while preserving first-seen group order', () => {
    const grouped = groupModelsByProvider([
      { model_id: 'a', group: 'OpenAI' },
      { model_id: 'b', group: 'Anthropic' },
      { model_id: 'c', group: 'OpenAI' },
      { model_id: 'd' },
    ]);

    expect(grouped.groupOrder).toEqual(['OpenAI', 'Anthropic', 'Other']);
    expect(grouped.groups.OpenAI.map((model) => model.model_id)).toEqual(['a', 'c']);
    expect(grouped.groups.Other.map((model) => model.model_id)).toEqual(['d']);
  });

  it('filters grouped models by every typed word across label, id and group', () => {
    expect(filterGroupedModels(groupedModels, '')).toBe(groupedModels);
    expect(filterGroupedModels(groupedModels, 'mini')).toEqual({ OpenAI: [groupedModels.OpenAI[1]] });
    expect(filterGroupedModels(groupedModels, 'GPT 5 MINI')).toEqual({ OpenAI: [groupedModels.OpenAI[1]] });
    expect(filterGroupedModels(groupedModels, 'anthropic')).toEqual({ Anthropic: groupedModels.Anthropic });
    expect(filterGroupedModels(groupedModels, 'openai/gpt-5-mini')).toEqual({ OpenAI: [groupedModels.OpenAI[1]] });
    expect(filterGroupedModels(groupedModels, 'opüs')).toEqual({ Anthropic: groupedModels.Anthropic });
    expect(filterGroupedModels(groupedModels, 'nothing like this')).toEqual({});
  });
});
