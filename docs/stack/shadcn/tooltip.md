# Tooltip Component

## Installation

```bash
bunx shadcn-svelte@latest add tooltip
```

## Usage

```svelte
<script>
  import * as Tooltip from "$lib/components/ui/tooltip";
  import { Button } from "$lib/components/ui/button";
</script>

<!-- Basic tooltip -->
<Tooltip.Root>
  <Tooltip.Trigger asChild>
    <Button variant="outline">Hover me</Button>
  </Tooltip.Trigger>
  <Tooltip.Content>
    <p>Add to library</p>
  </Tooltip.Content>
</Tooltip.Root>

<!-- With provider for multiple tooltips -->
<Tooltip.Provider>
  <Tooltip.Root>
    <Tooltip.Trigger asChild>
      <Button variant="outline" size="icon">
        <Plus class="h-4 w-4" />
      </Button>
    </Tooltip.Trigger>
    <Tooltip.Content>
      <p>Add item</p>
    </Tooltip.Content>
  </Tooltip.Root>
  
  <Tooltip.Root>
    <Tooltip.Trigger asChild>
      <Button variant="outline" size="icon">
        <Settings class="h-4 w-4" />
      </Button>
    </Tooltip.Trigger>
    <Tooltip.Content>
      <p>Settings</p>
    </Tooltip.Content>
  </Tooltip.Root>
</Tooltip.Provider>

<!-- Different positions -->
<Tooltip.Root>
  <Tooltip.Trigger>Hover</Tooltip.Trigger>
  <Tooltip.Content side="right">
    <p>Right side tooltip</p>
  </Tooltip.Content>
</Tooltip.Root>
```

## Props

### Tooltip.Content
- `side` - Position relative to trigger ('top' | 'right' | 'bottom' | 'left')
- `align` - Alignment ('start' | 'center' | 'end')
- `class` - Additional CSS classes

### Tooltip.Provider
- `delayDuration` - Delay before showing tooltip (ms)
- `skipDelayDuration` - Delay when moving between tooltips

## Documentation

- [Official Tooltip Documentation](https://www.shadcn-svelte.com/docs/components/tooltip)
- [Bits UI Tooltip](https://bits-ui.com/docs/components/tooltip)
