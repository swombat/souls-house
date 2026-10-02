import { render, fireEvent, screen, waitFor } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import ImportResident from './import.svelte';

const props = { account: { id: 'account' }, preview_url: '/preview', import_url: '/import' };
const archive = new File(['synthetic archive'], 'resident.tar.gz', { type: 'application/gzip' });
const preview = {
  name: 'Resident',
  export_id: 'export-uuid',
  source_resident_id: 'source-id',
  created_at: '2026-10-02T12:00:00Z',
  files_count: 3,
  graph_nodes: 2,
  graph_edges: 1,
  warnings: ['Services need reconnection.'],
  duplicate: true,
};

function response(data, ok = true) {
  return { ok, json: async () => data };
}

async function upload() {
  await fireEvent.change(screen.getByLabelText('Resident archive (.tar.gz)'), { target: { files: [archive] } });
  await fireEvent.click(screen.getByRole('button', { name: 'Preview archive' }));
}

beforeEach(() => {
  vi.stubGlobal('fetch', vi.fn());
  document.head.innerHTML = '<meta name="csrf-token" content="synthetic-csrf">';
});
afterEach(() => {
  vi.unstubAllGlobals();
  document.head.innerHTML = '';
});

test('validates selection before making a request', async () => {
  render(ImportResident, props);
  await fireEvent.click(screen.getByRole('button', { name: 'Preview archive' }));
  expect(screen.getByRole('alert')).toHaveTextContent('Choose a resident');
  expect(fetch).not.toHaveBeenCalled();
  expect(screen.queryByRole('button', { name: 'Import stopped copy' })).not.toBeInTheDocument();
});

test('previews then reuploads the original file with name and explicit fork confirmation', async () => {
  fetch.mockResolvedValueOnce(response({ preview })).mockResolvedValueOnce(response({ redirect_url: '/copy/edit' }));
  render(ImportResident, props);
  await upload();
  await screen.findByText('Archive preview');
  expect(screen.getByText(/already been imported/)).toBeInTheDocument();
  expect(screen.getByText('Services need reconnection.')).toBeInTheDocument();
  expect(screen.getByText('export-uuid')).toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Import stopped copy' })).toBeDisabled();
  const [url, options] = fetch.mock.calls[0];
  expect(url).toBe('/preview');
  expect(options.credentials).toBe('same-origin');
  expect(options.headers['X-CSRF-Token']).toBe('synthetic-csrf');
  expect(options.headers['Content-Type']).toBeUndefined();
  expect(options.body.get('archive')).toBe(archive);
  expect(options.body.has('confirmed')).toBe(false);
  await fireEvent.click(screen.getByRole('checkbox'));
  await fireEvent.input(screen.getByLabelText('Name for the new resident'), { target: { value: '  Copy  ' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Import stopped copy' }));
  await waitFor(() => expect(router.visit).toHaveBeenCalledWith('/copy/edit'));
  const [confirmUrl, confirmOptions] = fetch.mock.calls[1];
  expect(confirmUrl).toBe('/import');
  expect(confirmOptions.body.get('archive')).toBe(archive);
  expect(confirmOptions.body.get('name')).toBe('Copy');
  expect(confirmOptions.body.get('confirmed')).toBe('true');
  expect(router.post).not.toHaveBeenCalled();
});

test('changing files clears the preview and confirmation', async () => {
  fetch.mockResolvedValue(response({ preview }));
  render(ImportResident, props);
  await upload();
  await screen.findByText('Archive preview');
  await fireEvent.click(screen.getByRole('checkbox'));
  await fireEvent.change(screen.getByLabelText('Resident archive (.tar.gz)'), {
    target: { files: [new File(['other'], 'other.tar.gz')] },
  });
  expect(screen.queryByText('Archive preview')).not.toBeInTheDocument();
  await fireEvent.click(screen.getByRole('button', { name: 'Preview archive' }));
  await screen.findByText('Archive preview');
  expect(screen.getByRole('checkbox')).not.toBeChecked();
});

test.each([
  ['archive rejection', () => Promise.resolve(response({ error: 'Invalid checksum' }, false)), 'Invalid checksum'],
  ['network failure', () => Promise.reject(new Error('Network unavailable')), 'Network unavailable'],
  [
    'unreadable response',
    () =>
      Promise.resolve({
        ok: false,
        json: async () => {
          throw new SyntaxError();
        },
      }),
    'unreadable response',
  ],
  ['invalid preview', () => Promise.resolve(response({ preview: {} })), 'invalid preview'],
])('shows %s and allows retry', async (_label, result, message) => {
  fetch.mockImplementationOnce(result).mockResolvedValueOnce(response({ preview }));
  render(ImportResident, props);
  await upload();
  expect(await screen.findByRole('alert')).toHaveTextContent(message);
  expect(screen.queryByText('Archive preview')).not.toBeInTheDocument();
  await fireEvent.click(screen.getByRole('button', { name: 'Preview archive' }));
  await screen.findByText('Archive preview');
  expect(screen.queryByRole('alert')).not.toBeInTheDocument();
});

test('failed confirmation preserves the preview and displays name validation errors', async () => {
  fetch
    .mockResolvedValueOnce(response({ preview }))
    .mockResolvedValueOnce(response({ errors: { name: ['Name is taken'] } }, false));
  render(ImportResident, props);
  await upload();
  await screen.findByText('Archive preview');
  await fireEvent.click(screen.getByRole('checkbox'));
  await fireEvent.input(screen.getByLabelText('Name for the new resident'), { target: { value: ' ' } });
  expect(screen.getByRole('button', { name: 'Import stopped copy' })).toBeDisabled();
  await fireEvent.input(screen.getByLabelText('Name for the new resident'), { target: { value: 'Copy' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Import stopped copy' }));
  expect(await screen.findByRole('alert')).toHaveTextContent('Name is taken');
  expect(screen.getByText('Archive preview')).toBeInTheDocument();
  expect(router.visit).not.toHaveBeenCalled();
});

test('accepts a final server redirect without parsing its HTML', async () => {
  fetch.mockResolvedValueOnce(response({ preview })).mockResolvedValueOnce({
    ok: true,
    redirected: true,
    url: '/copy/edit',
    json: vi.fn(),
  });
  render(ImportResident, props);
  await upload();
  await screen.findByText('Archive preview');
  await fireEvent.click(screen.getByRole('checkbox'));
  await fireEvent.click(screen.getByRole('button', { name: 'Import stopped copy' }));
  await waitFor(() => expect(router.visit).toHaveBeenCalledWith('/copy/edit'));
});

test('disables file replacement and duplicate requests while uploading, and aborts on unmount', async () => {
  fetch.mockImplementation(() => new Promise(() => {}));
  const { unmount } = render(ImportResident, props);
  await upload();
  expect(screen.getByLabelText('Resident archive (.tar.gz)')).toBeDisabled();
  expect(screen.getByRole('button', { name: 'Uploading…' })).toBeDisabled();
  const signal = fetch.mock.calls[0][1].signal;
  expect(signal.aborted).toBe(false);
  unmount();
  expect(signal.aborted).toBe(true);
});
