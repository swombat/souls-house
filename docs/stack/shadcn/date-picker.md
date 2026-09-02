# Date Picker Component

## Installation

```bash
bunx shadcn-svelte@latest add date-picker
```

## Usage

```svelte
<script>
  import { DatePicker } from "$lib/components/ui/date-picker";
  
  let value = undefined;
</script>

<DatePicker bind:value />
```

## With Placeholder

```svelte
<script>
  import { DatePicker } from "$lib/components/ui/date-picker";
  
  let value = undefined;
</script>

<DatePicker bind:value placeholder="Pick a date" />
```

## Range Picker

```svelte
<script>
  import { DateRangePicker } from "$lib/components/ui/date-picker";
  
  let value = { start: undefined, end: undefined };
</script>

<DateRangePicker bind:value />
```

## With Preset Ranges

```svelte
<script>
  import { DateRangePicker } from "$lib/components/ui/date-picker";
  import { today, getLocalTimeZone } from "@internationalized/date";
  
  let value = { start: undefined, end: undefined };
  
  const presets = [
    {
      label: "Today",
      value: { start: today(getLocalTimeZone()), end: today(getLocalTimeZone()) }
    },
    {
      label: "Yesterday",
      value: { 
        start: today(getLocalTimeZone()).subtract({ days: 1 }), 
        end: today(getLocalTimeZone()).subtract({ days: 1 }) 
      }
    },
    {
      label: "Last 7 days",
      value: { 
        start: today(getLocalTimeZone()).subtract({ days: 6 }), 
        end: today(getLocalTimeZone()) 
      }
    },
  ];
</script>

<DateRangePicker bind:value {presets} />
```

## Form Integration

```svelte
<script>
  import { DatePicker } from "$lib/components/ui/date-picker";
  import { Button } from "$lib/components/ui/button";
  import { superForm } from "sveltekit-superforms/client";
  import { z } from "zod";
  
  const schema = z.object({
    dob: z.date(),
  });
  
  export let data;
  
  const { form, errors, enhance } = superForm(data.form, {
    validators: schema,
  });
</script>

<form method="POST" use:enhance>
  <DatePicker 
    bind:value={$form.dob}
    name="dob"
    error={$errors.dob?.[0]}
  />
  <Button type="submit">Submit</Button>
</form>
```

## Disabled Dates

```svelte
<script>
  import { DatePicker } from "$lib/components/ui/date-picker";
  import { today, getLocalTimeZone } from "@internationalized/date";
  
  let value = undefined;
  
  function isDateDisabled(date) {
    const today = new Date();
    return date < today;
  }
</script>

<DatePicker bind:value {isDateDisabled} />
```

## Props

### DatePicker
- `value` - Selected date
- `placeholder` - Placeholder text
- `isDateDisabled` - Function to disable specific dates
- `isDateUnavailable` - Function to mark dates as unavailable
- `minValue` - Minimum selectable date
- `maxValue` - Maximum selectable date
- `locale` - Date locale
- `disabled` - Disable the picker
- `readonly` - Make picker readonly
- `name` - Form field name
- `class` - Additional CSS classes

### DateRangePicker
- `value` - Selected date range ({ start, end })
- `placeholder` - Placeholder text
- `presets` - Predefined date ranges
- `isDateDisabled` - Function to disable specific dates
- `closeOnSelection` - Close picker after selection
- `numberOfMonths` - Number of months to display
- `class` - Additional CSS classes

## Documentation

- [Official Date Picker Documentation](https://www.shadcn-svelte.com/docs/components/date-picker)
- [Bits UI Date Picker Documentation](https://bits-ui.com/docs/components/date-picker)
