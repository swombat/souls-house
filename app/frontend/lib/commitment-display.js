// How a commitment's time and state read to a person. Shared by the
// resident's Commitments tab (AgentCommitmentsPanel) and the conversation's
// "Show commitments" sheet (ConversationCommitmentsDrawer).

export function commitmentWhen(value, zone) {
  if (!value) return null;
  return new Intl.DateTimeFormat('en-GB', {
    dateStyle: 'medium',
    timeStyle: 'short',
    timeZone: zone || 'UTC',
  }).format(new Date(value));
}

export const COMMITMENT_WAITING = {
  live_activity_disabled: 'live activity is switched off',
  resident_not_member: 'the resident is no longer in this house',
  billing_hold: 'the resident is held for billing',
  resident_paused: 'the resident is paused',
  resident_unavailable: 'the resident cannot run right now',
  conversation_unavailable: 'the conversation is archived',
  resident_not_in_conversation: 'the resident has left the conversation',
};

export function commitmentStatusLine(c, agentName = 'This resident') {
  const when = (value) => commitmentWhen(value, c.timezone);
  if (c.status === 'cancelled') {
    const what = c.wake_state === 'withdrawn' ? 'Stopped after it was posted' : 'Cancelled';
    return `${what} ${when(c.cancelled_at)}${c.cancelled_by ? ` by ${c.cancelled_by}` : ''}.`;
  }
  if (c.status === 'activated') {
    const delivered = `Posted ${when(c.activated_at)}.`;
    const wake = {
      delivered: `${agentName} has it: the run that carried it finished ${when(c.delivered_at)}.`,
      woken: `${agentName} has been woken for it.`,
      held: `${agentName} was busy there, so the wake waits for that run to end.`,
      retrying: `The wake has not reached ${agentName} yet (${COMMITMENT_WAITING[c.wake_reason] || c.wake_reason}); it is tried again every minute.`,
      blocked: `The house stopped trying to wake ${agentName} for it: ${c.wake_reason}.`,
    }[c.wake_state];
    return wake ? `${delivered} ${wake}` : delivered;
  }
  if (c.waiting_reason) {
    return `Due and waiting: ${COMMITMENT_WAITING[c.waiting_reason] || c.waiting_reason}. Tried ${when(c.last_attempted_at)}; tried again every minute.`;
  }
  return 'Scheduled.';
}
