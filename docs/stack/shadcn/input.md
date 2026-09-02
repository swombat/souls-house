# Input Component

## Installation

```bash
bunx shadcn-svelte@latest add input
```

## Usage

```svelte
<script>
  import { Input } from "$lib/components/ui/input";
  import { Label } from "$lib/components/ui/label";
</script>

<!-- Basic input -->
<Input type="text" placeholder="Enter your name" />

<!-- With label -->
<div class="grid w-full max-w-sm items-center gap-1.5">
  <Label for="email">Email</Label>
  <Input type="email" id="email" placeholder="Email" />
</div>

<!-- Different types -->
<Input type="password" placeholder="Password" />
<Input type="number" placeholder="Age" />
<Input type="date" />
<Input type="file" />

<!-- Disabled state -->
<Input disabled type="text" placeholder="Disabled input" />

<!-- With validation styling -->
<Input class="border-red-500" type="text" placeholder="Error state" />
```

## Input Types

- `text` - Standard text input
- `email` - Email input with validation
- `password` - Password input
- `number` - Numeric input
- `date` - Date picker
- `file` - File upload
- `search` - Search input
- `tel` - Telephone number
- `url` - URL input

## Props

- `type` - Input type
- `placeholder` - Placeholder text
- `disabled` - Disable input
- `readonly` - Make input read-only
- `value` - Input value (for binding)
- `class` - Additional CSS classes
- `id` - Input ID for label association
- `name` - Form field name
- `required` - Mark as required field

## Documentation

- [Official Input Documentation](https://www.shadcn-svelte.com/docs/components/input)
