# Menubar Component

## Installation

```bash
bunx shadcn-svelte@latest add menubar
```

## Usage

```svelte
<script>
  import * as Menubar from "$lib/components/ui/menubar";
</script>

<Menubar.Root>
  <Menubar.Menu>
    <Menubar.Trigger>File</Menubar.Trigger>
    <Menubar.Content>
      <Menubar.Item>New Tab</Menubar.Item>
      <Menubar.Item>New Window</Menubar.Item>
      <Menubar.Item disabled>New Incognito Window</Menubar.Item>
      <Menubar.Separator />
      <Menubar.Sub>
        <Menubar.SubTrigger>Share</Menubar.SubTrigger>
        <Menubar.SubContent>
          <Menubar.Item>Email link</Menubar.Item>
          <Menubar.Item>Messages</Menubar.Item>
          <Menubar.Item>Notes</Menubar.Item>
        </Menubar.SubContent>
      </Menubar.Sub>
      <Menubar.Separator />
      <Menubar.Item>Print...</Menubar.Item>
    </Menubar.Content>
  </Menubar.Menu>
  
  <Menubar.Menu>
    <Menubar.Trigger>Edit</Menubar.Trigger>
    <Menubar.Content>
      <Menubar.Item>Undo</Menubar.Item>
      <Menubar.Item>Redo</Menubar.Item>
      <Menubar.Separator />
      <Menubar.Item>Find</Menubar.Item>
    </Menubar.Content>
  </Menubar.Menu>
  
  <Menubar.Menu>
    <Menubar.Trigger>View</Menubar.Trigger>
    <Menubar.Content>
      <Menubar.CheckboxItem>Always Show Bookmarks Bar</Menubar.CheckboxItem>
      <Menubar.CheckboxItem checked>Always Show Full URLs</Menubar.CheckboxItem>
      <Menubar.Separator />
      <Menubar.Item inset>Reload</Menubar.Item>
      <Menubar.Item disabled inset>Force Reload</Menubar.Item>
    </Menubar.Content>
  </Menubar.Menu>
</Menubar.Root>
```

## With Keyboard Shortcuts

```svelte
<Menubar.Root>
  <Menubar.Menu>
    <Menubar.Trigger>File</Menubar.Trigger>
    <Menubar.Content>
      <Menubar.Item>
        New Tab
        <Menubar.Shortcut>⌘T</Menubar.Shortcut>
      </Menubar.Item>
      <Menubar.Item>
        New Window
        <Menubar.Shortcut>⌘N</Menubar.Shortcut>
      </Menubar.Item>
      <Menubar.Separator />
      <Menubar.Item>
        Save
        <Menubar.Shortcut>⌘S</Menubar.Shortcut>
      </Menubar.Item>
      <Menubar.Item>
        Print
        <Menubar.Shortcut>⌘P</Menubar.Shortcut>
      </Menubar.Item>
    </Menubar.Content>
  </Menubar.Menu>
</Menubar.Root>
```

## With Radio Groups

```svelte
<script>
  let person = "pedro";
</script>

<Menubar.Root>
  <Menubar.Menu>
    <Menubar.Trigger>Profiles</Menubar.Trigger>
    <Menubar.Content>
      <Menubar.RadioGroup bind:value={person}>
        <Menubar.RadioItem value="andy">Andy</Menubar.RadioItem>
        <Menubar.RadioItem value="benoit">Benoit</Menubar.RadioItem>
        <Menubar.RadioItem value="luis">Luis</Menubar.RadioItem>
        <Menubar.RadioItem value="pedro">Pedro</Menubar.RadioItem>
      </Menubar.RadioGroup>
      <Menubar.Separator />
      <Menubar.Item>Edit...</Menubar.Item>
      <Menubar.Item>Add...</Menubar.Item>
    </Menubar.Content>
  </Menubar.Menu>
</Menubar.Root>
```

## Application Menu Example

```svelte
<script>
  import * as Menubar from "$lib/components/ui/menubar";
  
  let showBookmarks = true;
  let showFullUrls = false;
  let selectedProfile = "default";
</script>

<Menubar.Root class="border">
  <Menubar.Menu>
    <Menubar.Trigger>File</Menubar.Trigger>
    <Menubar.Content>
      <Menubar.Item>
        New File
        <Menubar.Shortcut>⌘N</Menubar.Shortcut>
      </Menubar.Item>
      <Menubar.Item>
        Open File
        <Menubar.Shortcut>⌘O</Menubar.Shortcut>
      </Menubar.Item>
      <Menubar.Separator />
      <Menubar.Item>
        Save
        <Menubar.Shortcut>⌘S</Menubar.Shortcut>
      </Menubar.Item>
      <Menubar.Item>
        Save As...
        <Menubar.Shortcut>⌘⇧S</Menubar.Shortcut>
      </Menubar.Item>
    </Menubar.Content>
  </Menubar.Menu>
  
  <Menubar.Menu>
    <Menubar.Trigger>Edit</Menubar.Trigger>
    <Menubar.Content>
      <Menubar.Item>
        Undo
        <Menubar.Shortcut>⌘Z</Menubar.Shortcut>
      </Menubar.Item>
      <Menubar.Item>
        Redo
        <Menubar.Shortcut>⌘Y</Menubar.Shortcut>
      </Menubar.Item>
      <Menubar.Separator />
      <Menubar.Item>
        Cut
        <Menubar.Shortcut>⌘X</Menubar.Shortcut>
      </Menubar.Item>
      <Menubar.Item>
        Copy
        <Menubar.Shortcut>⌘C</Menubar.Shortcut>
      </Menubar.Item>
      <Menubar.Item>
        Paste
        <Menubar.Shortcut>⌘V</Menubar.Shortcut>
      </Menubar.Item>
    </Menubar.Content>
  </Menubar.Menu>
  
  <Menubar.Menu>
    <Menubar.Trigger>View</Menubar.Trigger>
    <Menubar.Content>
      <Menubar.CheckboxItem bind:checked={showBookmarks}>
        Show Bookmarks Bar
        <Menubar.Shortcut>⌘⇧B</Menubar.Shortcut>
      </Menubar.CheckboxItem>
      <Menubar.CheckboxItem bind:checked={showFullUrls}>
        Show Full URLs
      </Menubar.CheckboxItem>
      <Menubar.Separator />
      <Menubar.Item>
        Reload
        <Menubar.Shortcut>⌘R</Menubar.Shortcut>
      </Menubar.Item>
    </Menubar.Content>
  </Menubar.Menu>
</Menubar.Root>
```

## Props

### Root
- `value` - Currently open menu
- `onValueChange` - Value change handler
- `loop` - Loop through items with keyboard
- `class` - Additional CSS classes

### Menu
- `value` - Menu identifier

### Trigger
- `class` - Additional CSS classes

### Content
- `loop` - Loop through items
- `side` - Preferred side
- `sideOffset` - Side offset
- `align` - Alignment
- `class` - Additional CSS classes

### Item
- `disabled` - Disable the item
- `inset` - Add left padding
- `class` - Additional CSS classes

### CheckboxItem
- `checked` - Checkbox state
- `onCheckedChange` - State change handler
- `class` - Additional CSS classes

### RadioGroup
- `value` - Selected value
- `onValueChange` - Value change handler

### RadioItem
- `value` - Item value
- `class` - Additional CSS classes

## Documentation

- [Official Menubar Documentation](https://www.shadcn-svelte.com/docs/components/menubar)
- [Bits UI Menubar Documentation](https://bits-ui.com/docs/components/menubar)
