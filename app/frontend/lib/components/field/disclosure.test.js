import { render } from '@testing-library/svelte';
import SummariesNotice from './SummariesNotice.svelte';
import OcrNotice from './OcrNotice.svelte';

// What the Field says it sends (FieldSummaries, FieldOcr).
test('with OCR on, the upload notice says transcribed scans are summarised too', () => {
  const { container } = render(SummariesNotice, { kind: 'file', ocr: true });
  expect(container.textContent.replace(/\s+/g, ' ')).toContain(
    'including scanned pages once a model has transcribed them'
  );
  expect(container.textContent.replace(/\s+/g, ' ')).not.toContain('not scans');
  const ocr = render(OcrNotice, { kind: 'file' }).container.textContent.replace(/\s+/g, ' ');
  expect(ocr).toContain('an image of each such page (up to 50) is sent to Claude Haiku');
});

test('with OCR off, the upload notice says scans are not read', () => {
  const { container } = render(SummariesNotice, { kind: 'file', ocr: false });
  expect(container.textContent.replace(/\s+/g, ' ')).toContain('not scans');
});

test('the Field-wide notice covers already-transcribed scans whether or not OCR is on now', () => {
  const { container } = render(SummariesNotice, { kind: 'page' });
  expect(container.textContent.replace(/\s+/g, ' ')).toContain('including scanned PDF pages a model has transcribed');
});
