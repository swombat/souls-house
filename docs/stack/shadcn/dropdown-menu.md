# Dropdown Menu Component

## Installation

```bash
bunx shadcn-svelte@latest add dropdown-menu
```

## Usage

```svelte
<script>
  import * as DropdownMenu from "$lib/components/ui/dropdown-menu";
  import { Button } from "$lib/components/ui/button";
</script>

<!-- Basic dropdown menu -->
<DropdownMenu.Root>
  <DropdownMenu.Trigger asChild>
    <Button variant="outline">Open</Button>
  </DropdownMenu.Trigger>
  <DropdownMenu.Content class="w-56">
    <DropdownMenu.Label>My Account</DropdownMenu.Label>
    <DropdownMenu.Separator />
    <DropdownMenu.Group>
      <DropdownMenu.Item>
        Profile
        <DropdownMenu.Shortcut>⇧⌘P</DropdownMenu.Shortcut>
      </DropdownMenu.Item>
      <DropdownMenu.Item>
        Billing
        <DropdownMenu.Shortcut>⌘B</DropdownMenu.Shortcut>
      </DropdownMenu.Item>
      <DropdownMenu.Item>
        Settings
        <DropdownMenu.Shortcut>⌘S</DropdownMenu.Shortcut>
      </DropdownMenu.Item>
    </DropdownMenu.Group>
    <DropdownMenu.Separator />
    <DropdownMenu.Item>
      Log out
      <DropdownMenu.Shortcut>⇧⌘Q</DropdownMenu.Shortcut>
    </DropdownMenu.Item>
  </DropdownMenu.Content>
</DropdownMenu.Root>

<!-- With submenu -->
<DropdownMenu.Root>
  <DropdownMenu.Trigger asChild>
    <Button>Actions</Button>
  </DropdownMenu.Trigger>
  <DropdownMenu.Content>
    <DropdownMenu.Item>New Tab</DropdownMenu.Item>
    <DropdownMenu.Item>New Window</DropdownMenu.Item>
    <DropdownMenu.Separator />
    <DropdownMenu.Sub>
      <DropdownMenu.SubTrigger>More Tools</DropdownMenu.SubTrigger>
      <DropdownMenu.SubContent>
        <DropdownMenu.Item>Save Page As...</DropdownMenu.Item>
        <DropdownMenu.Item>Create Shortcut...</DropdownMenu.Item>
        <DropdownMenu.Item>Developer Tools</DropdownMenu.Item>
      </DropdownMenu.SubContent>
    </DropdownMenu.Sub>
  </DropdownMenu.Content>
</DropdownMenu.Root>
```

## Components

- `DropdownMenu.Root` - Root container
- `DropdownMenu.Trigger` - Trigger element
- `DropdownMenu.Content` - Menu content
- `DropdownMenu.Item` - Menu item
- `DropdownMenu.Label` - Menu label
- `DropdownMenu.Separator` - Visual separator
- `DropdownMenu.Group` - Group items
- `DropdownMenu.Sub` - Submenu
- `DropdownMenu.SubTrigger` - Submenu trigger
- `DropdownMenu.SubContent` - Submenu content
- `DropdownMenu.Shortcut` - Keyboard shortcut

## Documentation

- [Official Dropdown Menu Documentation](https://www.shadcn-svelte.com/docs/components/dropdown-menu)
- [Bits UI Dropdown Menu](https://bits-ui.com/docs/components/dropdown-menu)
