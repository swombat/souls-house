# Calendar Component

## Installation

```bash
bunx shadcn-svelte@latest add calendar
```

## Usage

```svelte
<script>
  import { Calendar } from "$lib/components/ui/calendar";
  
  let value = undefined;
</script>

<Calendar bind:value />
```

## With Default Value

```svelte
<script>
  import { Calendar } from "$lib/components/ui/calendar";
  import { today, getLocalTimeZone } from "@internationalized/date";
  
  let value = today(getLocalTimeZone());
</script>

<Calendar bind:value />
```

## Multiple Selection

```svelte
<script>
  import { Calendar } from "$lib/components/ui/calendar";
  
  let value = [];
</script>

<Calendar bind:value multiple />
```

## Range Selection

```svelte
<script>
  import { Calendar } from "$lib/components/ui/calendar";
  
  let value = { start: undefined, end: undefined };
</script>

<Calendar bind:value range />
```

## Disabled Dates

```svelte
<script>
  import { Calendar } from "$lib/components/ui/calendar";
  import { today, getLocalTimeZone } from "@internationalized/date";
  
  let value = undefined;
  
  function isDateDisabled(date) {
    return date.compare(today(getLocalTimeZone())) < 0;
  }
</script>

<Calendar bind:value {isDateDisabled} />
```

## Props

- `value` - Selected date(s)
- `multiple` - Enable multiple selection
- `range` - Enable range selection
- `isDateDisabled` - Function to disable specific dates
- `isDateUnavailable` - Function to mark dates as unavailable
- `minValue` - Minimum selectable date
- `maxValue` - Maximum selectable date
- `locale` - Calendar locale
- `class` - Additional CSS classes

## Documentation

- [Official Calendar Documentation](https://www.shadcn-svelte.com/docs/components/calendar)
- [Bits UI Calendar Documentation](https://bits-ui.com/docs/components/calendar)
