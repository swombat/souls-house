export function flattenGroupedModels(groupedModels = {}) {
  return Object.values(groupedModels).flat();
}

export function firstModelId(groupedModels = {}, fallback = 'openrouter/auto') {
  return flattenGroupedModels(groupedModels)[0]?.model_id ?? fallback;
}

export function findModel(groupedModels = {}, modelId) {
  return flattenGroupedModels(groupedModels).find((model) => model.model_id === modelId) || null;
}

export function findModelLabel(groupedModels = {}, modelId) {
  return findModel(groupedModels, modelId)?.label || modelId;
}

export function modelSupportsThinking(groupedModels = {}, modelId) {
  return findModel(groupedModels, modelId)?.supports_thinking === true;
}

export function groupModelsByProvider(models = []) {
  const groups = {};
  const groupOrder = [];

  for (const model of models) {
    const group = model.group || 'Other';
    if (!groups[group]) {
      groups[group] = [];
      groupOrder.push(group);
    }
    groups[group].push(model);
  }

  return { groups, groupOrder };
}

// Search for the model picker. Every word typed must appear somewhere in the
// model's label, id or provider group, so "gpt 4o mini" and "anthropic opus"
// both narrow the list. Accents and case are ignored.
const foldModelText = (value) =>
  String(value || '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase();

export function filterGroupedModels(groupedModels = {}, query = '') {
  const words = foldModelText(query).split(/\s+/).filter(Boolean);
  if (!words.length) return groupedModels;

  const filtered = {};
  for (const [groupName, models] of Object.entries(groupedModels)) {
    const matches = models.filter((model) => {
      const haystack = foldModelText(`${model.label} ${model.model_id} ${groupName}`);
      return words.every((word) => haystack.includes(word));
    });
    if (matches.length) filtered[groupName] = matches;
  }
  return filtered;
}
