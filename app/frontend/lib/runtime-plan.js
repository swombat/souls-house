// One line for the collapsed run card when the run carried a plan (#864):
// "3 of 7 · running the tests". Dropped steps leave the count; nothing is
// shown without a plan.
const MAX_STEP = 60;

function short(text) {
  const value = String(text || '')
    .replace(/\s+/g, ' ')
    .trim();
  return value.length > MAX_STEP ? `${value.slice(0, MAX_STEP - 1).trimEnd()}…` : value;
}

export function runtimePlanLine(snapshot) {
  const steps = Array.isArray(snapshot?.plan) ? snapshot.plan : [];
  const counted = steps.filter((step) => step?.status !== 'cancelled');
  if (!counted.length) return null;
  const done = counted.filter((step) => step.status === 'completed').length;
  const count = `${done} of ${counted.length}`;
  if (snapshot.plan_status === 'cancelled') return `${count} · stopped`;
  if (snapshot.plan_status === 'completed' || done === counted.length) return count;
  const working = counted.find((step) => step.status === 'in_progress');
  if (working) return `${count} · ${short(working.text)}`;
  const blocked = counted.find((step) => step.status === 'blocked');
  if (blocked) return `${count} · waiting: ${short(blocked.text)}`;
  const next = counted.find((step) => step.status === 'pending');
  return next ? `${count} · next: ${short(next.text)}` : count;
}
