import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { useForm } from '@inertiajs/svelte';
import NewResident from './new.svelte';

const houseModel = 'house/claude-haiku-5.5';
const draftKey = 'helixkit:agent-birth-draft:account';
const props = {
  account: { id: 'account' },
  default_model_id: houseModel,
  grouped_models: {
    'Top Models': [{ model_id: 'openai/gpt-6-astra', label: 'GPT-6 Astra' }],
    'On the house': [
      { model_id: houseModel, label: 'Claude Haiku 5.5 · On the house' },
      { model_id: 'house/deepseek-v4.1-flash', label: 'DeepSeek V4.1 Flash · On the house' },
    ],
  },
};

beforeEach(() => localStorage.clear());
afterEach(() => localStorage.clear());

test('import options wait behind one link below the form', async () => {
  render(NewResident, {
    ...props,
    github_resident_import_url: '/github-import/new',
    resident_import_url: '/import',
  });
  expect(screen.queryByRole('link', { name: 'Bring an existing GitHub resident' })).not.toBeInTheDocument();

  await fireEvent.click(screen.getByRole('button', { name: 'Import a resident instead' }));

  expect(screen.getByRole('link', { name: 'Bring an existing GitHub resident' })).toHaveAttribute(
    'href',
    '/github-import/new'
  );
  expect(screen.getByRole('link', { name: 'Import a resident archive' })).toHaveAttribute('href', '/import');
});

test('there is no import link without a server-provided URL', () => {
  render(NewResident, props);
  expect(screen.queryByRole('button', { name: 'Import a resident instead' })).not.toBeInTheDocument();
});

test('a fresh resident defaults to the house offering, not the first grouped model', async () => {
  render(NewResident, props);

  expect(useForm.mock.calls[0][0].agent.model_id).toBe(houseModel);
  await waitFor(() => expect(JSON.parse(localStorage.getItem(draftKey)).model_id).toBe(houseModel));
});

test('a saved draft keeps its chosen personal model', async () => {
  localStorage.setItem(draftKey, JSON.stringify({ model_id: 'openai/gpt-6-astra' }));
  render(NewResident, props);

  await waitFor(() => expect(JSON.parse(localStorage.getItem(draftKey)).model_id).toBe('openai/gpt-6-astra'));
});

test('a draft without a model uses the house default', async () => {
  localStorage.setItem(draftKey, JSON.stringify({ name: 'Uncommitted resident' }));
  render(NewResident, props);

  await waitFor(() => expect(JSON.parse(localStorage.getItem(draftKey)).model_id).toBe(houseModel));
  expect(JSON.parse(localStorage.getItem(draftKey)).name).toBe('Uncommitted resident');
});

test('an account that pays per resident gets a sixth step, Plan, and a draft reopens no later than Review', async () => {
  // jsdom has no Web Animations; the step change runs Svelte transitions.
  Element.prototype.animate ||= function () {
    const animation = { cancel() {}, finished: Promise.resolve(), onfinish: null };
    setTimeout(() => animation.onfinish?.());
    return animation;
  };
  localStorage.setItem(
    draftKey,
    JSON.stringify({ name: 'Aria', system_prompt: 'Be curious.', key_path: 'house', step: 5 })
  );
  render(NewResident, {
    ...props,
    billing: { can_pay: true, tiers: [], payment_method: null, contact_email: 'hello@example.com' },
  });

  expect(screen.getByText('Six small steps, a few minutes.', { exact: false })).toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Go to step 6: Plan' })).toBeInTheDocument();
  await waitFor(() =>
    expect(screen.getByRole('button', { name: 'Go to step 5: Review' })).toHaveAttribute('aria-current', 'step')
  );
});
