import { test, expect } from '@playwright/experimental-ct-svelte';
import Onboarding from '../../app/frontend/pages/agents/onboarding.svelte';

const KEYS = ['server_ordered', 'server_online', 'home_prepared', 'runtime_started', 'first_backup'];

function vmSteps(done) {
  return KEYS.map((key, i) => ({ key, label: key, detail: `${key} detail`, estimate: 'about a minute', done: i < done }));
}

function props(done, extra = {}) {
  const ready = done === KEYS.length;
  return {
    agent: {
      id: 7,
      name: 'Sprout',
      icon: 'robot',
      birth_committed_at: '2026-10-25T11:43:00Z',
      runtime: ready ? 'external' : 'provisioning',
      health_state: ready ? 'healthy' : 'unknown',
      orientation_requested_at: ready ? '2026-10-25T11:49:00Z' : null,
      ...extra.agent,
    },
    account: { id: 'acc' },
    vm_steps: vmSteps(done),
    first_resident: extra.first_resident ?? true,
    provisioning_retry_url: '/retry',
    orientation_retry_url: '/orient',
  };
}

test('a birth on its own server shows the picture for the step in progress', async ({ mount }, testInfo) => {
  for (let done = 0; done < KEYS.length; done++) {
    const page = await mount(Onboarding, { props: props(done) });
    await expect(page.getByTestId('setup-step-loop')).toHaveAttribute('data-step', KEYS[done]);
    await expect(page.getByText('Usually about a minute.')).toHaveCount(KEYS.length - done);
    if (process.env.STEP_SHOTS) {
      await page.page().waitForTimeout(Number(process.env.STEP_SHOTS));
      await page.screenshot({ path: testInfo.outputPath(`step-${done}-${KEYS[done]}.png`) });
    }
    await page.unmount();
  }
});

test('the first wake has its own picture, and a first resident gets no settings links', async ({ mount }, testInfo) => {
  const page = await mount(Onboarding, { props: props(KEYS.length) });
  await expect(page.getByTestId('setup-step-loop')).toHaveAttribute('data-step', 'first_wake');
  await expect(page.getByRole('link', { name: /Resident settings/ })).toHaveCount(0);
  await expect(page.getByRole('link', { name: /All residents/ })).toHaveCount(0);
  await expect(page.getByRole('link', { name: /Start your first conversation/ })).toBeVisible();
  if (process.env.STEP_SHOTS) {
    await page.page().waitForTimeout(Number(process.env.STEP_SHOTS));
    await page.screenshot({ path: testInfo.outputPath('step-5-first_wake.png') });
  }
});

test('no picture once the first wake is done, and other residents keep their links', async ({ mount }) => {
  const page = await mount(Onboarding, {
    props: props(KEYS.length, { agent: { orientation_completed_at: '2026-10-25T11:50:00Z' }, first_resident: false }),
  });
  await expect(page.getByTestId('setup-step-loop')).toHaveCount(0);
  await expect(page.getByRole('link', { name: /Resident settings/ })).toBeVisible();
});
