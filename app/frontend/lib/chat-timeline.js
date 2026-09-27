import { progressMessageGroups } from './progress-messages';

export function chatTimelineItems(allMessages = [], visibleMessages = allMessages, runtimeInteractions = []) {
  const items = progressMessageGroups(allMessages, visibleMessages).map((group) => ({
    type: 'message',
    id: `message-${group.message.id}`,
    created_at: group.message.created_at,
    message: group.message,
    group,
  }));
  const runtimeItems = (runtimeInteractions || []).map((interaction) => ({
    type: 'runtime_interaction',
    id: `runtime-${interaction.id}`,
    created_at: interaction.finished_at || interaction.started_at || interaction.created_at,
    interaction,
  }));
  runtimeItems.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));

  // Keep speech grouped and ordered independently: activity is an annotation,
  // not a spoken interruption. At equal times, place completion after speech.
  for (const runtime of runtimeItems.filter((item) => !item.interaction.active)) {
    const index = items.findIndex(
      (item) => item.type === 'message' && new Date(item.created_at) > new Date(runtime.created_at)
    );
    items.splice(index < 0 ? items.length : index, 0, runtime);
  }

  // Active work stays at the bottom, even as new replies/messages arrive.
  return [...items, ...runtimeItems.filter((item) => item.interaction.active)];
}
