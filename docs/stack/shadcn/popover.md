# Popover Component

## Installation

```bash
bunx shadcn-svelte@latest add popover
```

## Usage

```svelte
<script>
  import * as Popover from "$lib/components/ui/popover";
  import { Button } from "$lib/components/ui/button";
  import { Label } from "$lib/components/ui/label";
  import { Input } from "$lib/components/ui/input";
</script>

<!-- Basic popover -->
<Popover.Root>
  <Popover.Trigger asChild>
    <Button variant="outline">Open popover</Button>
  </Popover.Trigger>
  <Popover.Content class="w-80">
    <div class="grid gap-4">
      <div class="space-y-2">
        <h4 class="font-medium leading-none">Dimensions</h4>
        <p class="text-sm text-muted-foreground">
          Set the dimensions for the layer.
        </p>
      </div>
      <div class="grid gap-2">
        <div class="grid grid-cols-3 items-center gap-4">
          <Label for="width">Width</Label>
          <Input id="width" value="100%" class="col-span-2 h-8" />
        </div>
        <div class="grid grid-cols-3 items-center gap-4">
          <Label for="height">Height</Label>
          <Input id="height" value="25px" class="col-span-2 h-8" />
        </div>
      </div>
    </div>
  </Popover.Content>
</Popover.Root>

<!-- Different alignments -->
<Popover.Root>
  <Popover.Trigger asChild>
    <Button variant="outline">Align options</Button>
  </Popover.Trigger>
  <Popover.Content align="start">
    <p>Aligned to start</p>
  </Popover.Content>
</Popover.Root>
```

## Props

### Popover.Content
- `align` - Alignment relative to trigger ('start' | 'center' | 'end')
- `side` - Side position ('top' | 'right' | 'bottom' | 'left')
- `class` - Additional CSS classes

## Documentation

- [Official Popover Documentation](https://www.shadcn-svelte.com/docs/components/popover)
- [Bits UI Popover](https://bits-ui.com/docs/components/popover/llms.txt)
