import { describe, expect, it } from 'vitest';
import { compareRichValues, richTableRows, staticRichUi } from './rich-ui.js';

const leaf = (type = 'Text', props = { text: 'Hello' }) => ({
  version: 1,
  root: 'root',
  elements: { root: { type, props } },
});
const chain = (length) => ({
  version: 1,
  root: 'n0',
  elements: Object.fromEntries(
    Array.from({ length }, (_, i) => [
      `n${i}`,
      { type: 'Stack', props: {}, children: i + 1 < length ? [`n${i + 1}`] : [] },
    ])
  ),
});

describe('static rich UI contract', () => {
  it('rejects NUL strings and unsafe integral numbers, but preserves quoted large numbers', () => {
    expect(staticRichUi(leaf('Text', { text: 'Hello\0world' }))).toBeNull();
    expect(staticRichUi(leaf('Table', { columns: ['X'], rows: [['\0']] }))).toBeNull();
    for (const value of [Number.MAX_SAFE_INTEGER + 1, -(2 ** 53), 1e20, 1.5e20]) {
      expect(staticRichUi(leaf('Table', { columns: ['X'], rows: [[value]] }))).toBeNull();
      expect(
        staticRichUi(leaf('Chart', { kind: 'line', labels: ['A'], series: [{ name: 'X', values: [value] }] }))
      ).toBeNull();
    }
    expect(
      staticRichUi(leaf('Table', { columns: ['X'], rows: [[Number.MAX_SAFE_INTEGER], [1.5], ['9007199254740993']] }))
    ).not.toBeNull();
    expect(staticRichUi(leaf('Metric', { label: 'Exact', value: '9007199254740993' }))).not.toBeNull();
  });
  it('accepts only supported components and returns an owned projection', () => {
    const input = leaf();
    const result = staticRichUi(input);
    expect(result.elements.root.children).toEqual([]);
    result.elements.root.props.text = 'changed';
    expect(input.elements.root.props.text).toBe('Hello');
    for (const [type, props] of [
      ['Stack', {}],
      ['Card', { title: 'Group' }],
      ['Metric', { label: 'Count', value: '12', detail: 'Today' }],
      ['Table', { columns: ['Value'], rows: [[null], [true], [3], [''], ['12']] }],
      ['Chart', { kind: 'line', labels: ['Now'], series: [{ name: 'Count', values: [0] }] }],
    ])
      expect(staticRichUi(leaf(type, props))).not.toBeNull();
  });

  it('rejects unknown/future specs and extra keys at every level', () => {
    expect(staticRichUi({ ...leaf(), version: 2 })).toBeNull();
    expect(staticRichUi({ ...leaf(), state: {} })).toBeNull();
    expect(staticRichUi(leaf('iframe', { src: 'https://example.test' }))).toBeNull();
    expect(staticRichUi(leaf('Text', { text: 'Hello', html: '<b>Hi</b>' }))).toBeNull();
    for (const name of ['on', 'watch', 'repeat', 'visible', 'bindings', 'actions', 'slots']) {
      const input = leaf();
      input.elements.root[name] = {};
      expect(staticRichUi(input), name).toBeNull();
    }
    const chart = leaf('Chart', { kind: 'bar', labels: ['A'], series: [{ name: 'X', values: [1], on: {} }] });
    expect(staticRichUi(chart)).toBeNull();
  });

  it('rejects every dynamic expression before Renderer can resolve it', () => {
    for (const key of [
      '$computed',
      '$state',
      '$bindState',
      '$bindItem',
      '$item',
      '$index',
      '$template',
      '$cond',
      '$custom',
    ]) {
      expect(staticRichUi(leaf('Text', { text: { [key]: 'danger' } }))).toBeNull();
      expect(staticRichUi(leaf('Table', { columns: ['Value'], rows: [[{ [key]: 'danger' }]] }))).toBeNull();
    }
    expect(staticRichUi(leaf('Text', { text: () => 'code' }))).toBeNull();
    expect(staticRichUi(leaf('Metric', { label: 'Count', value: 12 }))).toBeNull();
  });

  it('enforces nonblank strings, Unicode lengths, identifiers, and leaf children', () => {
    expect(staticRichUi(leaf('Text', { text: '  ' }))).toBeNull();
    expect(staticRichUi(leaf('Card', { title: '' }))).toBeNull();
    expect(staticRichUi(leaf('Metric', { label: 'X', value: '1', detail: ' ' }))).toBeNull();
    expect(staticRichUi(leaf('Text', { text: '😀'.repeat(4000) }))).not.toBeNull();
    expect(staticRichUi(leaf('Text', { text: 'a'.repeat(4001) }))).toBeNull();
    for (const id of ['bad.key', 'a'.repeat(65), '__proto__', 'prototype', 'constructor']) {
      expect(
        staticRichUi({ version: 1, root: id, elements: JSON.parse(`{"${id}":{"type":"Stack","props":{}}}`) })
      ).toBeNull();
    }
    const spec = leaf();
    spec.elements.root.children = ['other'];
    spec.elements.other = { type: 'Text', props: { text: 'Other' } };
    expect(staticRichUi(spec)).toBeNull();
  });

  it('enforces tree size/depth, references, single parent, reachability and cycles', () => {
    expect(staticRichUi(chain(10))).not.toBeNull();
    expect(staticRichUi(chain(11))).toBeNull();
    const wide = {
      version: 1,
      root: 'root',
      elements: {
        root: { type: 'Stack', props: {}, children: Array.from({ length: 49 }, (_, i) => `n${i}`) },
        ...Object.fromEntries(Array.from({ length: 49 }, (_, i) => [`n${i}`, { type: 'Text', props: { text: 'X' } }])),
      },
    };
    expect(staticRichUi(wide)).not.toBeNull();
    wide.elements.extra = { type: 'Text', props: { text: 'X' } };
    expect(staticRichUi(wide)).toBeNull();
    for (const children of [['missing'], ['n1', 'n1'], ['n0']]) {
      const spec = chain(2);
      spec.elements.n0.children = children;
      expect(staticRichUi(spec)).toBeNull();
    }
    const orphan = chain(2);
    orphan.elements.n0.children = [];
    expect(staticRichUi(orphan)).toBeNull();
    const cyclic = chain(2);
    cyclic.elements.n1.children = ['n0'];
    expect(staticRichUi(cyclic)).toBeNull();
  });

  it('enforces table, chart and byte bounds and rejects malformed rows/series', () => {
    expect(staticRichUi(leaf('Table', { columns: ['X'], rows: Array.from({ length: 501 }, () => [1]) }))).toBeNull();
    expect(staticRichUi(leaf('Table', { columns: Array(21).fill('X'), rows: [] }))).toBeNull();
    expect(staticRichUi(leaf('Table', { columns: ['X'], rows: [[1, 2]] }))).toBeNull();
    expect(staticRichUi(leaf('Table', { columns: ['X'], rows: [[Infinity]] }))).toBeNull();
    expect(
      staticRichUi(leaf('Table', { columns: ['X'], rows: Array.from({ length: 100 }, () => ['x'.repeat(4000)]) }))
    ).toBeNull();
    const chart = { kind: 'line', labels: ['A'], series: [{ name: 'X', values: [1] }] };
    expect(staticRichUi(leaf('Chart', { ...chart, labels: Array(201).fill('A') }))).toBeNull();
    expect(staticRichUi(leaf('Chart', { ...chart, series: Array(9).fill(chart.series[0]) }))).toBeNull();
    expect(staticRichUi(leaf('Chart', { ...chart, series: [{ name: 'X', values: [NaN] }] }))).toBeNull();
    expect(staticRichUi(leaf('Chart', { ...chart, series: [{ name: 'X', values: [] }] }))).toBeNull();
    expect(staticRichUi(leaf('Table', { columns: Array(1), rows: [] }))).toBeNull();
  });
});

describe('local typed table interactions', () => {
  it('sorts numbers numerically, strings lexically, booleans as booleans, and null last', () => {
    const values = [null, '2', 10, true, '10', 2, false];
    expect(values.toSorted((a, b) => compareRichValues(a, b))).toEqual([2, 10, '10', '2', false, true, null]);
    expect(values.toSorted((a, b) => compareRichValues(a, b, -1))).toEqual([10, 2, '2', '10', true, false, null]);
  });
  it('filters locally without changing source rows', () => {
    const rows = [
      [3, 'Alpha'],
      [12, 'beta'],
      [null, 'ALPINE'],
    ];
    expect(richTableRows(rows, 'alp', 0, -1)).toEqual([
      [3, 'Alpha'],
      [null, 'ALPINE'],
    ]);
    expect(rows[0]).toEqual([3, 'Alpha']);
  });
});
