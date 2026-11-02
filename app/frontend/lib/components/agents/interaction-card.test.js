import { cleanup, render, screen } from '@testing-library/svelte';
import InteractionCard from './interaction-card.svelte';

afterEach(cleanup);

const base = {
  id: 's1',
  summary: 'Conversation reply',
  telemetry_state: 'complete',
  started_at: '2026-10-25T13:00:00Z',
  duration_ms: 4000,
  chat_id: 'c1',
  chat_title: 'Resident reflexes tab',
  tokens: {},
};

function renderCard(interaction) {
  return render(InteractionCard, { interaction, account: { id: 'a1' }, tokenColumns: [] });
}

test('shows the reflexes offered on the session posts and counts the rest', () => {
  renderCard({
    ...base,
    reflexes: {
      judged_count: 3,
      offered: [
        {
          id: 'j1',
          name: 'pr-review-ask',
          reminder: 'Tag Mira for review.',
          score: 0.96,
          message_id: 'm1',
          excerpt: 'PR #555 is up.',
        },
      ],
    },
  });

  expect(screen.getByTestId('session-reflexes')).toBeInTheDocument();
  expect(screen.getByText('pr-review-ask')).toBeInTheDocument();
  expect(screen.getByText('0.96')).toBeInTheDocument();
  expect(screen.getByText('Brought to mind: Tag Mira for review.')).toBeInTheDocument();
  expect(screen.getByText('On the post: “PR #555 is up.”')).toBeInTheDocument();
  expect(screen.getByText('1 offered, 2 checked and not offered')).toBeInTheDocument();
});

test('says nothing about reflexes when none were checked', () => {
  renderCard({ ...base, reflexes: { judged_count: 0, offered: [] } });
  expect(screen.queryByTestId('session-reflexes')).not.toBeInTheDocument();

  cleanup();
  renderCard(base);
  expect(screen.queryByTestId('session-reflexes')).not.toBeInTheDocument();
});

test('says why the house refused a scheduled run before sending it', () => {
  renderCard({ ...base, summary: 'Wake', setup_refusal: 'Edit the resident and set up credentials.' });
  expect(screen.getByTestId('setup-refusal')).toHaveTextContent(
    'Not sent to the resident: Edit the resident and set up credentials.',
  );
});

test('shows no refusal line for an ordinary run', () => {
  renderCard({ ...base });
  expect(screen.queryByTestId('setup-refusal')).not.toBeInTheDocument();
});
