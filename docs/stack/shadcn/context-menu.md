# Context Menu Component

## Installation

```bash
bunx shadcn-svelte@latest add context-menu
```

## Usage

```svelte
<script>
  import * as ContextMenu from "$lib/components/ui/context-menu";
</script>

<!-- Basic context menu -->
<ContextMenu.Root>
  <ContextMenu.Trigger class="flex h-[150px] w-[300px] items-center justify-center rounded-md border border-dashed text-sm">
    Right click here
  </ContextMenu.Trigger>
  <ContextMenu.Content class="w-64">
    <ContextMenu.Item>
      Back
      <ContextMenu.Shortcut>⌘[</ContextMenu.Shortcut>
    </ContextMenu.Item>
    <ContextMenu.Item disabled>
      Forward
      <ContextMenu.Shortcut>⌘]</ContextMenu.Shortcut>
    </ContextMenu.Item>
    <ContextMenu.Item>
      Reload
      <ContextMenu.Shortcut>⌘R</ContextMenu.Shortcut>
    </ContextMenu.Item>
    <ContextMenu.Sub>
      <ContextMenu.SubTrigger>More Tools</ContextMenu.SubTrigger>
      <ContextMenu.SubContent class="w-48">
        <ContextMenu.Item>
          Save Page As...
          <ContextMenu.Shortcut>⌘S</ContextMenu.Shortcut>
        </ContextMenu.Item>
        <ContextMenu.Item>Create Shortcut...</ContextMenu.Item>
        <ContextMenu.Item>Name Window...</ContextMenu.Item>
        <ContextMenu.Separator />
        <ContextMenu.Item>Developer Tools</ContextMenu.Item>
      </ContextMenu.SubContent>
    </ContextMenu.Sub>
    <ContextMenu.Separator />
    <ContextMenu.CheckboxItem checked>
      Show Bookmarks Bar
      <ContextMenu.Shortcut>⌘⇧B</ContextMenu.Shortcut>
    </ContextMenu.CheckboxItem>
    <ContextMenu.CheckboxItem>Show Full URLs</ContextMenu.CheckboxItem>
  </ContextMenu.Content>
</ContextMenu.Root>
```

## Components

- `ContextMenu.Root` - Root container
- `ContextMenu.Trigger` - Right-click area
- `ContextMenu.Content` - Menu content
- `ContextMenu.Item` - Menu item
- `ContextMenu.CheckboxItem` - Checkbox menu item
- `ContextMenu.RadioGroup` - Radio group
- `ContextMenu.RadioItem` - Radio menu item
- `ContextMenu.Label` - Menu label
- `ContextMenu.Separator` - Visual separator
- `ContextMenu.Shortcut` - Keyboard shortcut
- `ContextMenu.Sub` - Submenu
- `ContextMenu.SubTrigger` - Submenu trigger
- `ContextMenu.SubContent` - Submenu content

## Documentation

- [Official Context Menu Documentation](https://www.shadcn-svelte.com/docs/components/context-menu)
- [Bits UI Context Menu](https://bits-ui.com/docs/components/context-menu)
