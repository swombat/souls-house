import { render, screen } from '@testing-library/svelte';
import ModelProviderLogo from './ModelProviderLogo.svelte';

test.each([
  ['openai/gpt-5.5', 'OpenAI', 'openai'],
  ['anthropic/claude-opus-4', 'Anthropic', 'anthropic'],
  ['google/gemini-3.7-flash', 'Google', 'google'],
  ['x-ai/grok-4.6', 'xAI', 'xai'],
  ['deepseek/model', 'DeepSeek', 'deepseek'],
  ['mistralai/model', 'Mistral', 'mistral'],
  ['meta-llama/model', 'Meta', 'meta'],
  ['minimax/model', 'MiniMax', 'minimax'],
  ['moonshotai/model', 'Moonshot AI', 'moonshot'],
  ['qwen/model', 'Qwen', 'qwen'],
  ['z-ai/model', 'Z.ai', 'zai'],
  ['openrouter/auto', 'OpenRouter', 'openrouter'],
])('uses a local maker logo for %s', (modelId, name, filename) => {
  render(ModelProviderLogo, { modelId });
  expect(screen.getByAltText(`${name} logo`)).toHaveAttribute('src', `/model-providers/${filename}.svg`);
});

test('unknown model providers use a neutral icon rather than a broken image', () => {
  const { container } = render(ModelProviderLogo, { modelId: 'custom/example' });
  expect(container.querySelector('img')).not.toBeInTheDocument();
  expect(screen.getByLabelText('Model provider')).toBeInTheDocument();
});
