import { test, expect } from '@playwright/experimental-ct-svelte';
import FieldFileViewer from '../../app/frontend/lib/components/field/FieldFileViewer.svelte';

// A PDF's own text in the open file (FieldFile::PdfExtraction). Made-up content.
const base = {
  key: 'file-f1',
  kind: 'file',
  id: 'f1',
  title: 'Orchard ledger',
  note: null,
  filename: 'orchard-ledger.pdf',
  content_type: 'application/pdf',
  byte_size: 7646,
  uploader_name: 'Sam',
  uploader_kind: 'human',
  created_at: '2026-10-11T07:00:00Z',
  tags: [],
  download_url: '/rails/active_storage/blobs/x/orchard-ledger.pdf',
};

const extraction = {
  status: 'extracted',
  reason: null,
  page_count: 3,
  pages_with_text: 2,
  pages_without_text: 1,
  pages_failed: 0,
  pages_skipped: 0,
  text_source: 'native',
};

test('a PDF shows its pages, says which have no text, and shows markup as text', async ({ mount, page }) => {
  const component = await mount(FieldFileViewer, {
    props: {
      file: {
        ...base,
        text_extraction: extraction,
        pages: [
          { number: 1, status: 'text', source: 'native', text: 'Apricots and quinces.' },
          { number: 2, status: 'empty', source: null, text: null },
          { number: 3, status: 'text', source: 'native', text: '<b>not bold</b> walnut harvest' },
        ],
      },
      link: 'https://example.test/f1',
      onDelete: () => {},
    },
  });

  await expect(page.getByTestId('field-file-pdf-status')).toContainText('Text read from 2 pages of 3.');
  await expect(page.getByTestId('field-file-pdf-status')).toContainText('1 page has no text of its own');
  const pages = page.getByTestId('field-file-pdf-page');
  await expect(pages).toHaveCount(3);
  await expect(pages.nth(0)).toContainText('Apricots and quinces.');
  await expect(pages.nth(1)).toContainText('No text of its own (blank or scanned). Nothing read.');
  await expect(pages.nth(2)).toContainText('<b>not bold</b> walnut harvest');
  await expect(component.locator('b')).toHaveCount(0);
  await page.screenshot({ path: 'tmp/field-pdf-text.png', fullPage: true });
});

test('partial, encrypted and failed PDFs say so', async ({ mount, page }) => {
  const partial = await mount(FieldFileViewer, {
    props: {
      file: {
        ...base,
        text_extraction: {
          ...extraction,
          status: 'partial',
          reason: '1 page could not be read',
          pages_with_text: 1,
          pages_without_text: 0,
          pages_failed: 1,
        },
        pages: [
          { number: 1, status: 'text', source: 'native', text: 'Apricots.' },
          { number: 2, status: 'failed', source: null, reason: 'pdftotext took too long', text: null },
        ],
      },
      link: 'x',
      onDelete: () => {},
    },
  });
  await expect(page.getByTestId('field-file-pdf-status')).toContainText('Partly read: 1 page could not be read.');
  await expect(partial).toContainText('Could not be read: pdftotext took too long.');
  await partial.unmount();

  const locked = await mount(FieldFileViewer, {
    props: {
      file: { ...base, text_extraction: { ...extraction, status: 'encrypted', page_count: null }, pages: null },
      link: 'x',
      onDelete: () => {},
    },
  });
  await expect(locked).toContainText('This PDF needs a password to open, so the house does not read it.');
  await locked.unmount();

  const broken = await mount(FieldFileViewer, {
    props: {
      file: { ...base, text_extraction: { ...extraction, status: 'failed', reason: 'Not a PDF the house can open' } },
      link: 'x',
      onDelete: () => {},
    },
  });
  await expect(broken).toContainText('The house could not read this PDF: Not a PDF the house can open.');
});

test('a cut page, cut search text and a partial summary are labelled', async ({ mount, page }) => {
  await mount(FieldFileViewer, {
    props: {
      file: {
        ...base,
        summary_long: 'An orchard ledger.',
        summary_partial: true,
        text_extraction: {
          ...extraction,
          status: 'partial',
          reason: '1 page cut short (too much text)',
          pages_with_text: 1,
          pages_without_text: 0,
          pages_truncated: 1,
          search_text_truncated: true,
          page_count: 1,
        },
        pages: [
          {
            number: 1,
            status: 'text',
            source: 'native',
            text: 'Apricots',
            reason: 'Text cut at 256 kB; the rest of this page was not read',
          },
        ],
      },
      link: 'x',
      onDelete: () => {},
    },
  });
  await expect(page.getByTestId('field-file-summary-partial')).toContainText('from the readable pages only');
  await expect(page.getByTestId('field-file-pdf-status')).toContainText(
    'Partly read: 1 page cut short (too much text).'
  );
  await expect(page.getByTestId('field-file-pdf-status')).toContainText(
    'Search and summaries use only the beginning of the text.'
  );
  await expect(page.getByTestId('field-file-pdf-page-cut')).toContainText('the rest of this page was not read');
  await page.screenshot({ path: 'tmp/field-pdf-text-cut.png', fullPage: true });
});

test('a transcribed page shows the model text apart, labelled, with failures said plainly', async ({ mount, page }) => {
  await mount(FieldFileViewer, {
    props: {
      file: {
        ...base,
        text_extraction: {
          ...extraction,
          page_count: 3,
          pages_with_text: 1,
          pages_without_text: 2,
          pages_transcribed: 2,
          pages_transcription_failed: 1,
          transcription: 'done',
          text_source: 'native+model',
        },
        pages: [
          {
            number: 1,
            status: 'text',
            source: 'native+model',
            text: 'Quarterly note',
            transcription: {
              status: 'text',
              model: 'anthropic/claude-haiku-5.5',
              text: 'Quarterly note\nFigs: 42 euros.',
            },
          },
          {
            number: 2,
            status: 'empty',
            source: 'model',
            text: null,
            transcription: { status: 'text', model: 'anthropic/claude-haiku-5.5', text: '<i>receipt</i>' },
          },
          {
            number: 3,
            status: 'empty',
            source: null,
            text: null,
            transcription: { status: 'failed', reason: 'The transcription failed' },
          },
        ],
      },
      link: 'x',
      onDelete: () => {},
    },
  });
  await expect(page.getByTestId('field-file-pdf-status')).toContainText(
    '2 pages transcribed by Claude Haiku from an image of the page; transcriptions may contain mistakes.'
  );
  await expect(page.getByTestId('field-file-pdf-status')).toContainText('1 page could not be transcribed.');
  const transcriptions = page.getByTestId('field-file-pdf-transcription');
  await expect(transcriptions).toHaveCount(3);
  await expect(transcriptions.nth(0)).toContainText(
    'Transcribed by Claude Haiku from an image of the page. May contain mistakes.'
  );
  await expect(transcriptions.nth(0)).toContainText('Figs: 42 euros.');
  await expect(transcriptions.nth(1)).toContainText('<i>receipt</i>');
  await expect(page.locator('i')).toHaveCount(0);
  await expect(transcriptions.nth(2)).toContainText('Not transcribed: The transcription failed.');
  await expect(transcriptions.nth(2)).not.toContainText('Transcribed by');
  await expect(page.getByTestId('field-file-pdf-page').nth(1)).not.toContainText('Nothing read.');
  await page.screenshot({ path: 'tmp/field-pdf-transcribed.png', fullPage: true });
});

test('files that are not PDFs show no text section', async ({ mount, page }) => {
  await mount(FieldFileViewer, {
    props: { file: { ...base, content_type: 'text/plain', text_extraction: null }, link: 'x', onDelete: () => {} },
  });
  await expect(page.getByTestId('field-file-pdf-text')).toHaveCount(0);
});
