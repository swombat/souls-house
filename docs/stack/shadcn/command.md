# Command Component

## Installation

```bash
bunx shadcn-svelte@latest add command
```

## Usage

```svelte
<script>
  import * as Command from "$lib/components/ui/command";
</script>

<!-- Basic command palette -->
<Command.Root class="rounded-lg border shadow-md">
  <Command.Input placeholder="Type a command or search..." />
  <Command.List>
    <Command.Empty>No results found.</Command.Empty>
    <Command.Group heading="Suggestions">
      <Command.Item>
        <Calendar class="mr-2 h-4 w-4" />
        <span>Calendar</span>
      </Command.Item>
      <Command.Item>
        <Smile class="mr-2 h-4 w-4" />
        <span>Search Emoji</span>
      </Command.Item>
      <Command.Item>
        <Calculator class="mr-2 h-4 w-4" />
        <span>Calculator</span>
      </Command.Item>
    </Command.Group>
    <Command.Separator />
    <Command.Group heading="Settings">
      <Command.Item>
        <User class="mr-2 h-4 w-4" />
        <span>Profile</span>
        <Command.Shortcut>⌘P</Command.Shortcut>
      </Command.Item>
      <Command.Item>
        <CreditCard class="mr-2 h-4 w-4" />
        <span>Billing</span>
        <Command.Shortcut>⌘B</Command.Shortcut>
      </Command.Item>
      <Command.Item>
        <Settings class="mr-2 h-4 w-4" />
        <span>Settings</span>
        <Command.Shortcut>⌘S</Command.Shortcut>
      </Command.Item>
    </Command.Group>
  </Command.List>
</Command.Root>

<!-- Command dialog -->
<script>
  import { onMount } from "svelte";
  import * as Dialog from "$lib/components/ui/dialog";
  
  let open = false;
  
  onMount(() => {
    const down = (e) => {
      if (e.key === "k" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        open = !open;
      }
    };
    
    document.addEventListener("keydown", down);
    return () => document.removeEventListener("keydown", down);
  });
</script>

<p class="text-sm text-muted-foreground">
  Press{" "}
  <kbd class="pointer-events-none inline-flex h-5 select-none items-center gap-1 rounded border bg-muted px-1.5 font-mono text-[10px] font-medium text-muted-foreground opacity-100">
    <span class="text-xs">⌘</span>K
  </kbd>
</p>

<Dialog.Root bind:open>
  <Dialog.Content class="overflow-hidden p-0 shadow-lg">
    <Command.Root class="[&_[cmdk-group-heading]]:px-2 [&_[cmdk-group-heading]]:font-medium [&_[cmdk-group-heading]]:text-muted-foreground [&_[cmdk-group]:not([hidden])_~[cmdk-group]]:pt-0 [&_[cmdk-group]]:px-2 [&_[cmdk-input-wrapper]_svg]:h-5 [&_[cmdk-input-wrapper]_svg]:w-5 [&_[cmdk-input]]:h-12 [&_[cmdk-item]]:px-2 [&_[cmdk-item]]:py-3 [&_[cmdk-item]_svg]:h-5 [&_[cmdk-item]_svg]:w-5">
      <Command.Input
        placeholder="Type a command or search..."
        class="h-12"
      />
      <Command.List class="max-h-[300px] overflow-y-auto">
        <Command.Empty>No results found.</Command.Empty>
        <Command.Group heading="Quick Actions">
          <Command.Item onSelect={() => { open = false; /* handle action */ }}>
            <File class="mr-2 h-4 w-4" />
            New File
          </Command.Item>
          <Command.Item onSelect={() => { open = false; /* handle action */ }}>
            <Folder class="mr-2 h-4 w-4" />
            New Folder
          </Command.Item>
          <Command.Item onSelect={() => { open = false; /* handle action */ }}>
            <Search class="mr-2 h-4 w-4" />
            Search Files
          </Command.Item>
        </Command.Group>
        <Command.Separator />
        <Command.Group heading="Navigation">
          <Command.Item onSelect={() => { open = false; goto('/dashboard'); }}>
            <Home class="mr-2 h-4 w-4" />
            Dashboard
          </Command.Item>
          <Command.Item onSelect={() => { open = false; goto('/projects'); }}>
            <FolderOpen class="mr-2 h-4 w-4" />
            Projects
          </Command.Item>
          <Command.Item onSelect={() => { open = false; goto('/settings'); }}>
            <Settings class="mr-2 h-4 w-4" />
            Settings
          </Command.Item>
        </Command.Group>
      </Command.List>
    </Command.Root>
  </Dialog.Content>
</Dialog.Root>

<!-- Searchable list -->
<Command.Root>
  <Command.Input placeholder="Search frameworks..." />
  <Command.List>
    <Command.Empty>No framework found.</Command.Empty>
    <Command.Group heading="Frontend">
      <Command.Item value="svelte">
        <span>Svelte</span>
      </Command.Item>
      <Command.Item value="react">
        <span>React</span>
      </Command.Item>
      <Command.Item value="vue">
        <span>Vue</span>
      </Command.Item>
      <Command.Item value="angular">
        <span>Angular</span>
      </Command.Item>
    </Command.Group>
    <Command.Separator />
    <Command.Group heading="Backend">
      <Command.Item value="nodejs">
        <span>Node.js</span>
      </Command.Item>
      <Command.Item value="python">
        <span>Python</span>
      </Command.Item>
      <Command.Item value="go">
        <span>Go</span>
      </Command.Item>
      <Command.Item value="rust">
        <span>Rust</span>
      </Command.Item>
    </Command.Group>
  </Command.List>
</Command.Root>

<!-- Command with loading state -->
<script>
  let loading = false;
  let results = [];
  
  async function handleSearch(value) {
    if (!value) {
      results = [];
      return;
    }
    
    loading = true;
    try {
      const response = await fetch(`/api/search?q=${encodeURIComponent(value)}`);
      results = await response.json();
    } finally {
      loading = false;
    }
  }
</script>

<Command.Root>
  <Command.Input 
    placeholder="Search users..." 
    onValueChange={handleSearch}
  />
  <Command.List>
    {#if loading}
      <Command.Loading>
        <div class="flex items-center justify-center p-4">
          <Loader class="h-4 w-4 animate-spin" />
        </div>
      </Command.Loading>
    {:else if results.length === 0}
      <Command.Empty>No users found.</Command.Empty>
    {:else}
      <Command.Group heading="Users">
        {#each results as user}
          <Command.Item value={user.id}>
            <Avatar class="mr-2 h-6 w-6">
              <Avatar.Image src={user.avatar} alt={user.name} />
              <Avatar.Fallback>{user.name.charAt(0)}</Avatar.Fallback>
            </Avatar>
            <span>{user.name}</span>
          </Command.Item>
        {/each}
      </Command.Group>
    {/if}
  </Command.List>
</Command.Root>
```

## Components

- `Command.Root` - Command container and search logic
- `Command.Input` - Search input field
- `Command.List` - Container for command items
- `Command.Group` - Group of related commands
- `Command.Item` - Individual command item
- `Command.Empty` - Shown when no results found
- `Command.Loading` - Loading state indicator
- `Command.Separator` - Visual separator between groups
- `Command.Shortcut` - Keyboard shortcut display

## Props

### Command.Root
- `value` - Current search value
- `onValueChange` - Callback when search value changes
- `filter` - Custom filter function
- `shouldFilter` - Whether to filter automatically (default: true)
- `class` - Additional CSS classes

### Command.Input
- `placeholder` - Input placeholder text
- `value` - Input value
- `onValueChange` - Value change callback
- `class` - Additional CSS classes

### Command.Item
- `value` - Unique value for this item
- `disabled` - Whether item is disabled
- `onSelect` - Callback when item is selected
- `class` - Additional CSS classes

### Command.Group
- `heading` - Group heading text
- `class` - Additional CSS classes

## Patterns

### Command palette with keyboard shortcuts
```svelte
<script>
  let open = false;
  
  function handleKeydown(e) {
    if (e.key === "k" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      open = true;
    }
  }
</script>

<svelte:window on:keydown={handleKeydown} />

<Dialog.Root bind:open>
  <Dialog.Content>
    <Command.Root>
      <Command.Input placeholder="What would you like to do?" />
      <Command.List>
        <Command.Group heading="Actions">
          <Command.Item onSelect={() => handleAction('new')}>
            <Plus class="mr-2 h-4 w-4" />
            New Document
            <Command.Shortcut>⌘N</Command.Shortcut>
          </Command.Item>
        </Command.Group>
      </Command.List>
    </Command.Root>
  </Dialog.Content>
</Dialog.Root>
```

### Search with custom filtering
```svelte
<script>
  function customFilter(value, search) {
    // Custom search logic
    return value.toLowerCase().includes(search.toLowerCase()) ? 1 : 0;
  }
</script>

<Command.Root filter={customFilter}>
  <!-- Command content -->
</Command.Root>
```

## Use Cases

- Command palettes for applications
- Search interfaces
- Quick navigation menus
- Action launchers
- Filterable lists

## Best Practices

- Include keyboard shortcuts for common actions
- Group related commands together
- Use icons to improve visual scanning
- Implement proper loading states for async searches
- Make search input prominent and focused by default

## Documentation

- [Official Command Documentation](https://www.shadcn-svelte.com/docs/components/command)
- [Bits UI Command](https://bits-ui.com/docs/components/command)
