// Describe the destructive request before the dialog can allow it.
const plural = (count, one, many) => `${count} ${count === 1 ? one : many}`;

function lossesFor(list) {
  const prints = list.filter((voice) => voice.remembered).length;
  const samples = list.reduce((sum, voice) => sum + (voice.samples || 0), 0);
  const confirmed = list.reduce((sum, voice) => sum + (voice.confirmed_samples || 0), 0);
  const losses = [];
  if (prints) losses.push(plural(prints, 'learned voice print', 'learned voice prints'));
  if (samples) losses.push(`${plural(samples, 'sample', 'samples')}, and every confirm or reject given in review`);
  if (confirmed) losses.push(`including ${plural(confirmed, 'confirmed sample', 'confirmed samples')}`);
  return { losses, requireWord: confirmed > 0 };
}

export function forgetAllRequest(voices, base) {
  const kept = voices.filter((voice) => voice.remembered || voice.remember || (voice.samples || 0) > 0);
  return {
    title: 'Forget every voice in this Field?',
    ...lossesFor(kept),
    keeps: 'every name given to a speaker, on every transcript. Learning can start again from those names.',
    confirmLabel: 'Forget all voices',
    url: `${base}/prints`,
  };
}

export function forgetVoiceRequest(voice, base) {
  return {
    title: `Forget ${voice.name}'s voice?`,
    ...lossesFor([voice]),
    keeps: `the name ${voice.name}, wherever someone gave it. Learning stops until "Remember again".`,
    confirmLabel: 'Forget voice',
    url: `${base}/${voice.id}/print`,
  };
}

export function deleteNameRequest(voice, base) {
  const { losses, requireWord } = lossesFor([voice]);
  return {
    title: `Delete ${voice.name}?`,
    losses: [`the name ${voice.name}: speakers named ${voice.name} go back to 'Speaker N' everywhere`, ...losses],
    requireWord,
    keeps: '',
    confirmLabel: 'Delete name',
    url: `${base}/${voice.id}`,
  };
}
