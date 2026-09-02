# Sheet Component

## Installation

```bash
bunx shadcn-svelte@latest add sheet
```

## Usage

```svelte
<script>
  import * as Sheet from "$lib/components/ui/sheet";
  import { Button } from "$lib/components/ui/button";
  import { Input } from "$lib/components/ui/input";
  import { Label } from "$lib/components/ui/label";
</script>

<!-- Basic sheet -->
<Sheet.Root>
  <Sheet.Trigger asChild>
    <Button variant="outline">Open</Button>
  </Sheet.Trigger>
  <Sheet.Content>
    <Sheet.Header>
      <Sheet.Title>Edit profile</Sheet.Title>
      <Sheet.Description>
        Make changes to your profile here. Click save when you're done.
      </Sheet.Description>
    </Sheet.Header>
    <div class="grid gap-4 py-4">
      <div class="grid grid-cols-4 items-center gap-4">
        <Label for="name" class="text-right">Name</Label>
        <Input id="name" value="John Doe" class="col-span-3" />
      </div>
      <div class="grid grid-cols-4 items-center gap-4">
        <Label for="username" class="text-right">Username</Label>
        <Input id="username" value="@johndoe" class="col-span-3" />
      </div>
    </div>
    <Sheet.Footer>
      <Sheet.Close asChild>
        <Button type="submit">Save changes</Button>
      </Sheet.Close>
    </Sheet.Footer>
  </Sheet.Content>
</Sheet.Root>

<!-- Different sides -->
<div class="grid grid-cols-2 gap-2">
  <Sheet.Root>
    <Sheet.Trigger asChild>
      <Button variant="outline">Right</Button>
    </Sheet.Trigger>
    <Sheet.Content side="right">
      <Sheet.Header>
        <Sheet.Title>Right Sheet</Sheet.Title>
      </Sheet.Header>
    </Sheet.Content>
  </Sheet.Root>
  
  <Sheet.Root>
    <Sheet.Trigger asChild>
      <Button variant="outline">Left</Button>
    </Sheet.Trigger>
    <Sheet.Content side="left">
      <Sheet.Header>
        <Sheet.Title>Left Sheet</Sheet.Title>
      </Sheet.Header>
    </Sheet.Content>
  </Sheet.Root>
  
  <Sheet.Root>
    <Sheet.Trigger asChild>
      <Button variant="outline">Top</Button>
    </Sheet.Trigger>
    <Sheet.Content side="top">
      <Sheet.Header>
        <Sheet.Title>Top Sheet</Sheet.Title>
      </Sheet.Header>
    </Sheet.Content>
  </Sheet.Root>
  
  <Sheet.Root>
    <Sheet.Trigger asChild>
      <Button variant="outline">Bottom</Button>
    </Sheet.Trigger>
    <Sheet.Content side="bottom">
      <Sheet.Header>
        <Sheet.Title>Bottom Sheet</Sheet.Title>
      </Sheet.Header>
    </Sheet.Content>
  </Sheet.Root>
</div>
```

## Props

### Sheet.Content
- `side` - Position of the sheet ('right' | 'left' | 'top' | 'bottom')
  - Default: 'right'
- `class` - Additional CSS classes

## Documentation

- [Official Sheet Documentation](https://www.shadcn-svelte.com/docs/components/sheet)
- [Bits UI Sheet](https://bits-ui.com/docs/components/sheet)
