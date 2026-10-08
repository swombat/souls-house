import { render, screen, waitFor } from '@testing-library/svelte';
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

test('existing GitHub residents have a separate server-authorized entry point', () => {
  render(NewResident, { ...props, github_resident_import_url: '/github-import/new' });
  expect(screen.getByRole('link', { name: 'Bring an existing GitHub resident instead' })).toHaveAttribute(
    'href',
    '/github-import/new'
  );
});

test('the GitHub import entry is absent without a server-provided URL', () => {
  render(NewResident, props);
  expect(screen.queryByRole('link', { name: 'Bring an existing GitHub resident instead' })).not.toBeInTheDocument();
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
