import { router } from '@inertiajs/svelte';
import { sendTestRequestAccountAgentPath, sendOrientationAccountAgentPath } from '@/routes';
export function createHostingActions(context) {
  let sendingOrientation = $state(false);
  let sendingTestRequest = $state(false);
  let recreatingSandbox = $state(false);
  let orientationResult = $state(null);
  let testResult = $state(null);
  function recreateSandbox() {
    if (!context().sandboxRecreationUrl || recreatingSandbox) return;

    if (
      !confirm(
        'Refresh this hosted sandbox runtime? This replaces the container with one built from the current runtime image. The identity and Chaos volumes will be preserved, but any container-local files outside mounted volumes will be lost.'
      )
    ) {
      return;
    }

    recreatingSandbox = true;
    router.post(
      context().sandboxRecreationUrl,
      {},
      {
        preserveScroll: true,
        onFinish() {
          recreatingSandbox = false;
        },
      }
    );
  }

  function csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || '';
  }

  function sendTestRequest() {
    sendingTestRequest = true;
    testResult = null;

    fetch(sendTestRequestAccountAgentPath(context().account.id, context().agent.id), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': csrfToken(),
      },
    })
      .then((response) => response.json().then((body) => ({ ok: response.ok, body })))
      .then(({ ok, body }) => {
        testResult = ok ? body : { status: 'transport_failed', error: body.error || 'Test request failed' };
        context().onrefresh();
      })
      .catch((error) => {
        testResult = { status: 'transport_failed', error: error.message };
      })
      .finally(() => {
        sendingTestRequest = false;
      });
  }

  function sendOrientation() {
    sendingOrientation = true;
    orientationResult = null;

    fetch(sendOrientationAccountAgentPath(context().account.id, context().agent.id), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': csrfToken(),
      },
    })
      .then((response) => response.json().then((body) => ({ ok: response.ok, body })))
      .then(({ ok, body }) => {
        orientationResult = ok ? body : { status: 'transport_failed', error: body.error || 'Orientation failed' };
        router.reload({ only: ['agent', 'interactions'], preserveScroll: true });
        context().onrefresh();
      })
      .catch((error) => {
        orientationResult = { status: 'transport_failed', error: error.message };
      })
      .finally(() => {
        sendingOrientation = false;
      });
  }

  return {
    get sendingOrientation() {
      return sendingOrientation;
    },
    get sendingTestRequest() {
      return sendingTestRequest;
    },
    get recreatingSandbox() {
      return recreatingSandbox;
    },
    get orientationResult() {
      return orientationResult;
    },
    get testResult() {
      return testResult;
    },
    sendOrientation,
    sendTestRequest,
    recreateSandbox,
  };
}
