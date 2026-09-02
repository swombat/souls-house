# Collapsible Component

## Installation

```bash
bunx shadcn-svelte@latest add collapsible
```

## Usage

```svelte
<script>
  import * as Collapsible from "$lib/components/ui/collapsible";
  import { Button } from "$lib/components/ui/button";
  import { CaretDown } from "phosphor-svelte";
  
  let isOpen = false;
</script>

<Collapsible.Root bind:open={isOpen} class="w-[350px] space-y-2">
  <div class="flex items-center justify-between space-x-4 px-4">
    <h4 class="text-sm font-semibold">
      @peduarte starred 3 repositories
    </h4>
    <Collapsible.Trigger asChild let:builder>
      <Button builders={[builder]} variant="ghost" size="sm" class="w-9 p-0">
        <CaretDown class="h-4 w-4" />
        <span class="sr-only">Toggle</span>
      </Button>
    </Collapsible.Trigger>
  </div>
  
  <div class="rounded-md border px-4 py-3 font-mono text-sm">
    @radix-ui/primitives
  </div>
  
  <Collapsible.Content class="space-y-2">
    <div class="rounded-md border px-4 py-3 font-mono text-sm">
      @radix-ui/colors
    </div>
    <div class="rounded-md border px-4 py-3 font-mono text-sm">
      @stitches/react
    </div>
  </Collapsible.Content>
</Collapsible.Root>
```

## Controlled

```svelte
<script>
  import * as Collapsible from "$lib/components/ui/collapsible";
  import { Button } from "$lib/components/ui/button";
  
  let isOpen = true;
  
  function toggle() {
    isOpen = !isOpen;
  }
</script>

<Collapsible.Root bind:open={isOpen}>
  <Collapsible.Trigger asChild let:builder>
    <Button builders={[builder]} variant="outline">
      Toggle Collapsible
    </Button>
  </Collapsible.Trigger>
  
  <Collapsible.Content>
    <p class="mt-2 text-sm text-muted-foreground">
      This content is collapsible and controlled externally.
    </p>
  </Collapsible.Content>
</Collapsible.Root>

<Button on:click={toggle} variant="secondary" class="mt-2">
  External Toggle
</Button>
```

## Props

### Root
- `open` - Whether the collapsible is open
- `disabled` - Disable the collapsible
- `class` - Additional CSS classes

### Trigger
- `asChild` - Render as a child component
- `class` - Additional CSS classes

### Content
- `forceMount` - Force mount the content
- `class` - Additional CSS classes

## Documentation

- [Official Collapsible Documentation](https://www.shadcn-svelte.com/docs/components/collapsible)
- [Bits UI Collapsible Documentation](https://bits-ui.com/docs/components/collapsible)
