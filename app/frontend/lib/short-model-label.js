// A shorter model label for narrow screens: drops the family prefix that
// every model from one provider shares. "Claude Opus 5.5" -> "Opus 5.5",
// "GPT-6.1 Sol" -> "Sol 6.1", "GPT-6 Astra Pro" -> "Astra Pro 6".
// Anything else is returned unchanged.
export function shortModelLabel(label) {
  if (!label) return label;
  const claude = label.match(/^Claude\s+(.+)$/);
  if (claude) return claude[1];
  const gpt = label.match(/^GPT-(\S+)\s+(.+)$/);
  if (gpt) return `${gpt[2]} ${gpt[1]}`;
  return label;
}
