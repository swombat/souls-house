# Label Component

## Installation

```bash
bunx shadcn-svelte@latest add label
```

## Usage

```svelte
<script>
  import { Label } from "$lib/components/ui/label";
  import { Input } from "$lib/components/ui/input";
  import { Checkbox } from "$lib/components/ui/checkbox";
</script>

<!-- Basic label -->
<Label for="username">Username</Label>

<!-- With input -->
<div class="space-y-2">
  <Label for="email">Email address</Label>
  <Input type="email" id="email" placeholder="name@example.com" />
</div>

<!-- With checkbox -->
<div class="flex items-center space-x-2">
  <Checkbox id="terms" />
  <Label for="terms">Accept terms and conditions</Label>
</div>

<!-- Required field indicator -->
<Label for="required-field">
  Name <span class="text-red-500">*</span>
</Label>

<!-- With description -->
<div class="space-y-1">
  <Label for="bio">Bio</Label>
  <p class="text-sm text-muted-foreground">
    Tell us a little bit about yourself
  </p>
</div>
```

## Props

- `for` - Associates label with form control
- `class` - Additional CSS classes

## Accessibility

- Always use the `for` attribute to associate labels with form controls
- Labels improve form accessibility and usability
- Clicking a label focuses/activates the associated control

## Documentation

- [Official Label Documentation](https://www.shadcn-svelte.com/docs/components/label)
