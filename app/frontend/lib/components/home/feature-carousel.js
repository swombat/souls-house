import { relationalFeatures, technicalFeatures } from '$lib/components/features/feature-list.js';

// The home carousel takes the features that have a clip and alternates the two sides of the
// Features page: a relational one, then a technical one, until both run out.
export function alternatingClipFeatures(relational = relationalFeatures, technical = technicalFeatures) {
  const withClip = (list, side) => list.filter((f) => f.media?.kind === 'video').map((f) => ({ ...f, side }));
  const life = withClip(relational, 'A life');
  const house = withClip(technical, 'A working house');
  const out = [];
  for (let i = 0; i < Math.max(life.length, house.length); i++) {
    if (life[i]) out.push(life[i]);
    if (house[i]) out.push(house[i]);
  }
  return out;
}
