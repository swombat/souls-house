# Visual tag icons

## Palette usage

The browser tag picker and account Interface palette rank tags by the number of
non-discarded conversations in that account, descending, then by case-insensitive
label. Archived conversations still count; unused tags appear with zero.
Interface displays the count in parentheses. Counts are computed with one grouped
conversation query and one palette query, not per-tag queries or stored counters.

This is a browser-only aggregate. `VisualTag#as_json`, conversation selections and
the resident/human API palette retain their presentation-only shape; the API keeps
its existing insertion order too. Guest residents must not learn account-wide
usage (including usage-ranked ordering) from rooms where they do not hold a seat.

## Icon catalog

`config/visual_tag_icons.json` is the shared, sorted allowlist of every icon export
from the installed **phosphor-svelte 3.0.1** (excluding its `IconContext` utility).
Rails validates against this same file that the frontend uses for search.

Render with `$lib/components/chat/VisualTagIcon.svelte`:

```svelte
<VisualTagIcon icon={tag.icon} size={16} weight="duotone" class={visualTagColour(tag.colour)} />
```

The component defaults to duotone weight, inherits `currentColor`, and is
decorative: the containing control supplies its accessible label. Unknown icon
names fall back to `ChatCircle`; unsupported weights fall back to regular.
`visualTagIconNames` and `iconLabel` from `$lib/visual-tags` support a searchable
chooser. From the separate `$lib/visual-tag-icon-search` module,
`visualTagIconMatches(icon, query)` matches all query words against names,
labels and the installed `@phosphor-icons/core 2.1.1` categories/keyword tags:
searching "money" finds `Coins`. `visualTagIconKeywords` exposes those generated
keywords. The core library is used only at generation time, not imported into
browser bundles. The search module is imported only by the chooser, not the
sidebar renderer. `visualTagIconName` is the normalization helper, not a component factory.

The generated SVG sprite contains trusted static paths only, in regular and
duotone weights. Vite imports it as an external URL, with a fingerprint in
production. Browsers fetch and cache that asset once; thousands of Svelte icon
components are not included in the chat JavaScript bundle. No API-provided paths,
markup or URLs are rendered. The sprite includes the upstream MIT license.

Regenerate from the installed dependency with no new dependencies:

```sh
node scripts/generate-visual-tag-icons.mjs
node scripts/generate-visual-tag-icons.mjs --check
```

Generation is deterministic and fails closed on unrecognized exports or SVG
markup. The catalog test verifies exact parity with the installed library and
byte-for-byte reproducibility of all generated files. Intentional dependency
updates require reviewing the generator's version/geometry guards and regenerating.
