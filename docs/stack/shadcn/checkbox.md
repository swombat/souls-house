# Checkbox Component

## Installation

```bash
bunx shadcn-svelte@latest add checkbox
```

## Usage

```svelte
<script>
  import { Checkbox } from "$lib/components/ui/checkbox";
  import { Label } from "$lib/components/ui/label";
  
  let checked = false;
  let terms = false;
</script>

<!-- Basic checkbox -->
<Checkbox />

<!-- With label -->
<div class="flex items-center space-x-2">
  <Checkbox id="terms" bind:checked={terms} />
  <Label for="terms">Accept terms and conditions</Label>
</div>

<!-- Controlled checkbox -->
<Checkbox bind:checked={checked} />
<p>Checked: {checked}</p>

<!-- Disabled state -->
<div class="flex items-center space-x-2">
  <Checkbox id="disabled" disabled />
  <Label for="disabled" class="opacity-50">Disabled option</Label>
</div>

<!-- With description -->
<div class="items-top flex space-x-2">
  <Checkbox id="notifications" />
  <div class="grid gap-1.5 leading-none">
    <Label for="notifications">
      Email notifications
    </Label>
    <p class="text-sm text-muted-foreground">
      Receive emails about your account activity.
    </p>
  </div>
</div>

<!-- Indeterminate state -->
<Checkbox checked="indeterminate" />
```

## Props

- `checked` - Checkbox state (boolean or 'indeterminate')
- `disabled` - Disable checkbox
- `id` - Checkbox ID for label association
- `name` - Form field name
- `value` - Checkbox value for forms
- `required` - Mark as required field
- `class` - Additional CSS classes

## States

- `false` - Unchecked
- `true` - Checked
- `'indeterminate'` - Indeterminate state (partially checked)

## Events

- `on:change` - Fired when checkbox state changes
- `on:click` - Click event handler

## Documentation

- [Official Checkbox Documentation](https://www.shadcn-svelte.com/docs/components/checkbox)
- [Bits UI Checkbox](https://bits-ui.com/docs/components/checkbox)
