import { untrack } from 'svelte';

// General's single-value settings follow server baselines, not every refresh.
// This protects local drafts; it is not an optimistic-concurrency contract.
export function createAccountSettingDraft(accountId, serverValue) {
  let identity = accountId();
  let observed = String(serverValue() ?? '');
  let baseline = $state(observed);
  let value = $state(observed);
  let saving = $state(false);
  let revision = 0;
  let request = 0;

  $effect(() => {
    const nextId = accountId();
    const next = String(serverValue() ?? '');
    untrack(() => {
      if (identity !== nextId) {
        identity = nextId;
        observed = baseline = value = next;
        saving = false;
        revision += 1;
        request += 1;
      } else if (observed !== next) {
        const pristine = value === baseline;
        observed = baseline = next;
        if (pristine && !saving) value = next;
      }
    });
  });

  return {
    get value() {
      return value;
    },
    set value(next) {
      value = String(next ?? '');
      revision += 1;
    },
    get saving() {
      return saving;
    },
    save(send, acceptedValue) {
      if (saving) return;
      const id = identity;
      const generation = ++request;
      const submittedRevision = revision;
      const submitted = value;
      const current = () => accountId() === id && request === generation;
      saving = true;
      send(submitted, {
        preserveScroll: true,
        preserveState: true,
        onSuccess: (page) => {
          // AccountsController reports validation refusals as redirect alerts,
          // which Inertia still delivers through onSuccess.
          if (!current() || page.props.flash?.alert) return;
          baseline = String(acceptedValue(page) ?? submitted);
          // Even typing away and back is a newer edit, not this save's draft.
          if (revision === submittedRevision) value = baseline;
        },
        onFinish: () => {
          if (current()) saving = false;
        },
      });
    },
  };
}
