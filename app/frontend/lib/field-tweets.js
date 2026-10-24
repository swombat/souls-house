// Tweets in the Field: pure helpers shared by the list, the search results,
// the viewer and the stream panel. Kept free of Svelte so they can be unit
// tested.

// What a tweet card calls itself beyond "post": a reply or a quote (a
// repost carries no text of its own) named by whichever kind fits first.
export function tweetBadge(kinds = []) {
  if (kinds?.includes('repost')) return 'Repost';
  if (kinds?.includes('quote')) return 'Quote';
  if (kinds?.includes('reply')) return 'Reply';
  return null;
}

export const STREAM_STATE_LABELS = {
  syncing: 'Up to date',
  backlogged: 'Catching up',
  waiting: 'Waiting',
  paused: 'Paused',
  needs_attention: 'Needs attention',
};

export function streamStateLabel(state) {
  return STREAM_STATE_LABELS[state] || state;
}

const METRIC_LABELS = [
  ['likes', 'likes'],
  ['reposts', 'reposts'],
  ['replies', 'replies'],
  ['quotes', 'quotes'],
  ['views', 'views'],
  ['bookmarks', 'bookmarks'],
];

// Only the metrics a tweet actually carries (any subset may be missing),
// in a fixed, readable order.
export function metricEntries(metrics) {
  if (!metrics) return [];
  return METRIC_LABELS.filter(([key]) => metrics[key] != null).map(([key, label]) => ({
    key,
    label,
    value: metrics[key],
  }));
}
