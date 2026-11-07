// This is intentionally narrower than json-render's Spec. Never pass wire data
// directly to Renderer: its expression and action languages are not our contract.
const LIMIT_BYTES = 256 * 1024;
const own = (object, key) => Object.hasOwn(object, key);
const object = (value) =>
  value !== null &&
  typeof value === 'object' &&
  !Array.isArray(value) &&
  [Object.prototype, null].includes(Object.getPrototypeOf(value));
const keys = (value, allowed, required = []) =>
  object(value) && Object.keys(value).every((key) => allowed.includes(key)) && required.every((key) => own(value, key));
const string = (value, max = 4000) => typeof value === 'string' && !value.includes('\0') && [...value].length <= max;
const nonblank = (value, max = 4000) => string(value, max) && value.trim().length > 0;
const finite = (value) =>
  typeof value === 'number' && Number.isFinite(value) && (!Number.isInteger(value) || Number.isSafeInteger(value));
const primitive = (value) => value === null || string(value) || finite(value) || typeof value === 'boolean';
const optionalString = (props, name, max = 4000) => !own(props, name) || nonblank(props[name], max);
const array = (value, max, check) => Array.isArray(value) && value.length <= max && Array.from(value).every(check);

function validProps(type, props) {
  switch (type) {
    case 'Stack':
      return keys(props, []);
    case 'Card':
      return keys(props, ['title']) && optionalString(props, 'title', 200);
    case 'Text':
      return keys(props, ['text'], ['text']) && nonblank(props.text);
    case 'Metric':
      return (
        keys(props, ['label', 'value', 'detail'], ['label', 'value']) &&
        nonblank(props.label, 200) &&
        nonblank(props.value) &&
        optionalString(props, 'detail')
      );
    case 'Table':
      return (
        keys(props, ['title', 'columns', 'rows'], ['columns', 'rows']) &&
        optionalString(props, 'title', 200) &&
        array(props.columns, 20, (column) => nonblank(column, 200)) &&
        props.columns.length > 0 &&
        array(
          props.rows,
          500,
          (row) => array(row, props.columns.length, primitive) && row.length === props.columns.length
        )
      );
    case 'Chart':
      return (
        keys(props, ['title', 'kind', 'labels', 'series'], ['kind', 'labels', 'series']) &&
        optionalString(props, 'title', 200) &&
        ['line', 'bar'].includes(props.kind) &&
        array(props.labels, 200, (label) => nonblank(label, 200)) &&
        props.labels.length > 0 &&
        array(
          props.series,
          8,
          (series) =>
            keys(series, ['name', 'values'], ['name', 'values']) &&
            nonblank(series.name, 200) &&
            array(series.values, props.labels.length, finite) &&
            series.values.length === props.labels.length
        ) &&
        props.series.length > 0
      );
    default:
      return false;
  }
}

/** Return an owned static projection, or null; unknown/future fields fail closed. */
export function staticRichUi(value) {
  try {
    if (
      !keys(value, ['version', 'root', 'elements', 'fallback'], ['version', 'root', 'elements']) ||
      value.version !== 1
    )
      return null;
    if (own(value, 'fallback') && !nonblank(value.fallback, 3500)) return null;
    if (!string(value.root, 200) || !object(value.elements)) return null;
    const ids = Object.keys(value.elements);
    if (ids.length === 0 || ids.length > 50 || !own(value.elements, value.root)) return null;
    for (const id of ids) {
      if (!/^[a-zA-Z0-9_-]{1,64}$/.test(id) || ['__proto__', 'prototype', 'constructor'].includes(id)) return null;
      const node = value.elements[id];
      if (!keys(node, ['type', 'props', 'children'], ['type', 'props']) || !validProps(node.type, node.props))
        return null;
      if (
        own(node, 'children') &&
        !array(node.children, 50, (child) => typeof child === 'string' && own(value.elements, child))
      )
        return null;
      if (!['Card', 'Stack'].includes(node.type) && (node.children?.length ?? 0) > 0) return null;
    }
    const visited = new Set();
    function visit(id, depth) {
      if (depth > 10 || visited.has(id)) return false;
      visited.add(id);
      return (value.elements[id].children ?? []).every((child) => visit(child, depth + 1));
    }
    if (!visit(value.root, 1) || visited.size !== ids.length) return null;
    let budget = 0;
    const json = JSON.stringify(value, (_key, item) => {
      budget += typeof item === 'string' ? new TextEncoder().encode(item).length : 1;
      if (budget > LIMIT_BYTES) throw new Error('Rich UI byte limit');
      return item;
    });
    if (new TextEncoder().encode(json).length > LIMIT_BYTES) return null;
    // No caller-owned objects (or inherited fields) reach json-render.
    const result = JSON.parse(json);
    delete result.fallback;
    for (const node of Object.values(result.elements)) node.children ??= [];
    return result;
  } catch {
    return null;
  }
}

// Only explicitly designated fallback prose may be collapsed. Legacy messages,
// mismatches and unsupported views retain their complete authored content.
export function richMessageProse(content, value) {
  if (typeof content !== 'string' || !staticRichUi(value) || !own(value, 'fallback'))
    return { content, fallback: null };
  const fallback = value.fallback;
  if (content === fallback) return { content: '', fallback };
  const suffix = `\n\n${fallback}`;
  return content.endsWith(suffix)
    ? { content: content.slice(0, -suffix.length), fallback }
    : { content, fallback: null };
}

export function displayRichValue(value) {
  return value === null ? '—' : String(value);
}

// Type groups stay stable in either direction. Only values within a group reverse.
// In particular, "12" is a string, false is a boolean, and null is always last.
export function compareRichValues(left, right, direction = 1) {
  const rank = (value) => (value === null ? 3 : typeof value === 'number' ? 0 : typeof value === 'string' ? 1 : 2);
  if (rank(left) !== rank(right)) return rank(left) - rank(right);
  if (left === null) return 0;
  const comparison = typeof left === 'string' ? left.localeCompare(right) : left === right ? 0 : left < right ? -1 : 1;
  return comparison * direction;
}

export function richTableRows(rows, filter, column, direction) {
  const query = filter.trim().toLocaleLowerCase();
  const filtered = rows.filter(
    (row) => !query || row.some((cell) => displayRichValue(cell).toLocaleLowerCase().includes(query))
  );
  return column === null ? filtered : filtered.toSorted((a, b) => compareRichValues(a[column], b[column], direction));
}
