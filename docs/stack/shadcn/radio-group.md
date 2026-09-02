# Radio Group Component

## Installation

```bash
bunx shadcn-svelte@latest add radio-group
```

## Usage

```svelte
<script>
  import { Label } from "$lib/components/ui/label";
  import { RadioGroup, RadioGroupItem } from "$lib/components/ui/radio-group";
  
  let value = "option-one";
</script>

<!-- Basic radio group -->
<RadioGroup bind:value>
  <div class="flex items-center space-x-2">
    <RadioGroupItem value="option-one" id="option-one" />
    <Label for="option-one">Option One</Label>
  </div>
  <div class="flex items-center space-x-2">
    <RadioGroupItem value="option-two" id="option-two" />
    <Label for="option-two">Option Two</Label>
  </div>
</RadioGroup>

<!-- With descriptions -->
<RadioGroup bind:value class="grid gap-4">
  <div class="flex items-start space-x-3">
    <RadioGroupItem value="default" id="r1" class="mt-1" />
    <div>
      <Label for="r1" class="font-medium">Default</Label>
      <p class="text-sm text-muted-foreground">
        Uses default notification settings
      </p>
    </div>
  </div>
  <div class="flex items-start space-x-3">
    <RadioGroupItem value="all" id="r2" class="mt-1" />
    <div>
      <Label for="r2" class="font-medium">All notifications</Label>
      <p class="text-sm text-muted-foreground">
        Receive all notifications
      </p>
    </div>
  </div>
  <div class="flex items-start space-x-3">
    <RadioGroupItem value="none" id="r3" class="mt-1" />
    <div>
      <Label for="r3" class="font-medium">No notifications</Label>
      <p class="text-sm text-muted-foreground">
        Turn off all notifications
      </p>
    </div>
  </div>
</RadioGroup>

<!-- Horizontal layout -->
<RadioGroup bind:value orientation="horizontal" class="flex gap-4">
  <div class="flex items-center space-x-2">
    <RadioGroupItem value="sm" id="size-sm" />
    <Label for="size-sm">Small</Label>
  </div>
  <div class="flex items-center space-x-2">
    <RadioGroupItem value="md" id="size-md" />
    <Label for="size-md">Medium</Label>
  </div>
  <div class="flex items-center space-x-2">
    <RadioGroupItem value="lg" id="size-lg" />
    <Label for="size-lg">Large</Label>
  </div>
</RadioGroup>

<!-- Disabled options -->
<RadioGroup>
  <div class="flex items-center space-x-2">
    <RadioGroupItem value="enabled" id="enabled" />
    <Label for="enabled">Enabled option</Label>
  </div>
  <div class="flex items-center space-x-2 opacity-50">
    <RadioGroupItem value="disabled" id="disabled" disabled />
    <Label for="disabled">Disabled option</Label>
  </div>
</RadioGroup>
```

## Props

### RadioGroup
- `value` - Selected value
- `orientation` - Layout orientation ('vertical' | 'horizontal')
- `disabled` - Disable entire group
- `class` - Additional CSS classes

### RadioGroupItem
- `value` - Option value
- `id` - Radio button ID
- `disabled` - Disable individual option
- `class` - Additional CSS classes

## Documentation

- [Official Radio Group Documentation](https://www.shadcn-svelte.com/docs/components/radio-group)
- [Bits UI Radio Group](https://bits-ui.com/docs/components/radio-group)
