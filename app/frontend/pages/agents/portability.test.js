import { render, fireEvent, screen, waitFor } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import EditResident from './edit.svelte';
import ResidentIndex from './index.svelte';
import NewResident from './new.svelte';
import PortabilityPanel from '$lib/components/agents/resident-portability-panel.svelte';

vi.mock('$lib/use-sync', () => ({ useSync: vi.fn() }));

const account = { id: 'account' };
const portability = { can_manage: true, export_ready: true, export_url: '/export', import_url: '/import' };
const editProps = { account, agent: { id: 'resident', name: 'Resident' }, portability };

test('owner can select the export/import tab with no settings submit action', async () => {
  render(EditResident, editProps);
  await fireEvent.click(screen.getByRole('button', { name: 'Export / Import' }));
  expect(screen.getByRole('link', { name: 'Download resident archive' })).toHaveAttribute('href', '/export');
  expect(screen.getByRole('link', { name: 'Import a resident archive' })).toHaveAttribute('href', '/import');
  expect(screen.getByText('Confidential, unencrypted archive')).toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Update Resident' })).not.toBeInTheDocument();
});

test('non-owner cannot see the tab or transfer links', () => {
  render(EditResident, { ...editProps, active_tab: 'portability', portability: { ...portability, can_manage: false } });
  expect(screen.queryByRole('button', { name: 'Export / Import' })).not.toBeInTheDocument();
  expect(screen.queryByRole('link', { name: 'Download resident archive' })).not.toBeInTheDocument();
  expect(screen.queryByRole('link', { name: 'Import a resident archive' })).not.toBeInTheDocument();
});

test.each(['Stop the resident before exporting.', 'External graph export is unavailable.'])(
  'not-ready export shows %s without a download link',
  (reason) => {
    render(PortabilityPanel, { portability: { ...portability, export_ready: false, unavailable_reason: reason } });
    expect(screen.getByRole('status')).toHaveTextContent(reason);
    expect(screen.queryByRole('link', { name: 'Download resident archive' })).not.toBeInTheDocument();
  }
);

test('an empty resident index still offers import', () => {
  render(ResidentIndex, { account, resident_import_url: '/import' });
  expect(screen.getByRole('link', { name: 'Import a resident archive' })).toHaveAttribute('href', '/import');
});

test('new resident page offers import without creating a resident', () => {
  render(NewResident, { account, resident_import_url: '/import', default_model_id: 'house/model' });
  expect(screen.getByRole('link', { name: 'Import a resident archive instead' })).toHaveAttribute('href', '/import');
});

test('index has no import entry when server does not grant it', () => {
  render(ResidentIndex, { account });
  expect(screen.queryByRole('link', { name: 'Import a resident archive' })).not.toBeInTheDocument();
});

describe('explicit portability lifecycle actions', () => {
  beforeEach(() => {
    vi.stubGlobal('fetch', vi.fn());
    document.head.innerHTML = '<meta name="csrf-token" content="synthetic-csrf">';
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    document.head.innerHTML = '';
  });

  function panel(extra = {}) {
    return render(PortabilityPanel, {
      portability: { ...portability, stop_url: '/stop', activate_url: '/activate', ...extra },
    });
  }

  test('stop requires impact confirmation and sends authenticated JSON', async () => {
    fetch.mockResolvedValue({ ok: true, json: async () => ({}) });
    panel();
    const button = screen.getByRole('button', { name: 'Stop for export' });
    expect(button).toBeDisabled();
    expect(fetch).not.toHaveBeenCalled();
    expect(screen.getByText(/does not kill the turn/)).toBeInTheDocument();
    await fireEvent.click(screen.getByLabelText(/I understand stopping/));
    await fireEvent.click(button);
    await waitFor(() => expect(router.reload).toHaveBeenCalledWith({ only: ['portability', 'agent'] }));
    expect(fetch).toHaveBeenCalledWith(
      '/stop',
      expect.objectContaining({
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          Accept: 'application/json',
          'Content-Type': 'application/json',
          'X-CSRF-Token': 'synthetic-csrf',
        },
        body: JSON.stringify({ confirmed: true }),
      })
    );
    expect(screen.getByLabelText(/I understand stopping/)).not.toBeChecked();
  });

  test('restored start requires archive trust and service review, never starts automatically', async () => {
    fetch.mockResolvedValue({ ok: true, json: async () => ({ redirect_url: '/resident/edit' }) });
    panel({ imported: true });
    const button = screen.getByRole('button', { name: 'Start restored resident' });
    expect(button).toBeDisabled();
    expect(fetch).not.toHaveBeenCalled();
    expect(screen.getByText(/First start executes archived code/)).toHaveTextContent('Scheduled wakes stay disabled');
    await fireEvent.click(screen.getByLabelText(/I have reviewed and trust the archived code/));
    await fireEvent.click(button);
    await waitFor(() => expect(router.visit).toHaveBeenCalledWith('/resident/edit'));
    expect(fetch).toHaveBeenCalledWith(
      '/activate',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ confirmed: true }),
      })
    );
    expect(router.post).not.toHaveBeenCalled();
  });

  test('source resume needs explicit confirmation but not archive review', async () => {
    fetch.mockResolvedValue({ ok: true, status: 204 });
    panel({ imported: false });
    const button = screen.getByRole('button', { name: 'Resume resident' });
    expect(button).toBeDisabled();
    expect(screen.queryByLabelText(/I have reviewed and trust/)).not.toBeInTheDocument();
    expect(screen.getByText(/Existing schedule preferences are preserved/)).toBeInTheDocument();
    await fireEvent.click(screen.getByLabelText(/I confirm this resident may resume/));
    await fireEvent.click(button);
    await waitFor(() => expect(router.reload).toHaveBeenCalledWith({ only: ['portability', 'agent'] }));
    expect(fetch.mock.calls[0][0]).toBe('/activate');
  });

  test('busy stop exposes refusal and refreshes paused state without activation', async () => {
    fetch.mockResolvedValue({
      ok: false,
      json: async () => ({ error: 'A turn is still active. Resident paused to drain.' }),
    });
    panel();
    await fireEvent.click(screen.getByLabelText(/I understand stopping/));
    await fireEvent.click(screen.getByRole('button', { name: 'Stop for export' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Resident paused to drain.');
    expect(router.reload).toHaveBeenCalledWith({ only: ['portability', 'agent'] });
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(router.visit).not.toHaveBeenCalled();
  });

  test('network failures show a curated uncertainty message, not raw diagnostics', async () => {
    fetch.mockRejectedValue(new Error('private diagnostic details'));
    panel();
    await fireEvent.click(screen.getByLabelText(/I confirm this resident may resume/));
    await fireEvent.click(screen.getByRole('button', { name: 'Resume resident' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Could not confirm the result');
    expect(screen.queryByText(/private diagnostic/)).not.toBeInTheDocument();
    expect(router.reload).not.toHaveBeenCalled();
  });

  test('pending action disables both controls and aborts when panel unmounts', async () => {
    fetch.mockImplementation(() => new Promise(() => {}));
    const { unmount } = panel();
    await fireEvent.click(screen.getByLabelText(/I understand stopping/));
    await fireEvent.click(screen.getByLabelText(/I confirm this resident may resume/));
    await fireEvent.click(screen.getByRole('button', { name: 'Stop for export' }));
    expect(screen.getByRole('button', { name: 'Stopping…' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Resume resident' })).toBeDisabled();
    const signal = fetch.mock.calls[0][1].signal;
    unmount();
    expect(signal.aborted).toBe(true);
  });

  test('server must supply action URLs and owner authority', () => {
    panel({ can_manage: false, imported: true });
    expect(screen.queryByRole('button', { name: 'Stop for export' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Start restored resident' })).not.toBeInTheDocument();
    expect(fetch).not.toHaveBeenCalled();
  });

  test('missing URLs hide lifecycle controls even for owners', () => {
    panel({ stop_url: null, activate_url: null, imported: true });
    expect(screen.queryByRole('button')).not.toBeInTheDocument();
    expect(fetch).not.toHaveBeenCalled();
  });
});
