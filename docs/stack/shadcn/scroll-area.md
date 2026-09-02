# Scroll Area Component

## Installation

```bash
bunx shadcn-svelte@latest add scroll-area
```

## Usage

```svelte
<script>
  import { ScrollArea } from "$lib/components/ui/scroll-area";
  import { Separator } from "$lib/components/ui/separator";
  
  const tags = Array.from({ length: 50 }, (_, i) => `Tag ${i + 1}`);
</script>

<!-- Basic scroll area -->
<ScrollArea class="h-72 w-48 rounded-md border">
  <div class="p-4">
    <h4 class="mb-4 text-sm font-medium leading-none">Tags</h4>
    {#each tags as tag}
      <div class="text-sm">{tag}</div>
      <Separator class="my-2" />
    {/each}
  </div>
</ScrollArea>

<!-- Horizontal scroll -->
<ScrollArea class="w-96 whitespace-nowrap rounded-md border">
  <div class="flex w-max space-x-4 p-4">
    {#each Array(20) as _, i}
      <figure class="shrink-0">
        <div class="overflow-hidden rounded-md">
          <img
            src={`/photo-${i + 1}.jpg`}
            alt={`Photo ${i + 1}`}
            class="aspect-[3/4] h-fit w-fit object-cover"
            width={150}
            height={200}
          />
        </div>
        <figcaption class="pt-2 text-xs text-muted-foreground">
          Photo {i + 1}
        </figcaption>
      </figure>
    {/each}
  </div>
</ScrollArea>

<!-- Chat messages -->
<Card.Root>
  <Card.Header>
    <Card.Title>Chat</Card.Title>
  </Card.Header>
  <Card.Content>
    <ScrollArea class="h-[400px] pr-4">
      {#each messages as message}
        <div class="mb-4 flex items-start gap-4">
          <Avatar>
            <AvatarImage src={message.avatar} />
            <AvatarFallback>{message.initials}</AvatarFallback>
          </Avatar>
          <div class="space-y-1">
            <div class="flex items-center gap-2">
              <p class="text-sm font-medium">{message.name}</p>
              <p class="text-xs text-muted-foreground">{message.time}</p>
            </div>
            <p class="text-sm">{message.content}</p>
          </div>
        </div>
      {/each}
    </ScrollArea>
  </Card.Content>
</Card.Root>

<!-- Code viewer -->
<ScrollArea class="h-[400px] w-full rounded-md border">
  <pre class="p-4">
    <code class="language-javascript">{codeContent}</code>
  </pre>
</ScrollArea>

<!-- List with search -->
<div class="space-y-4">
  <Input
    type="search"
    placeholder="Search items..."
    bind:value={searchQuery}
  />
  <ScrollArea class="h-[300px] rounded-md border">
    <div class="p-4">
      {#each filteredItems as item}
        <button
          class="flex w-full items-center rounded-lg p-2 text-left hover:bg-accent"
        >
          <div>
            <p class="text-sm font-medium">{item.title}</p>
            <p class="text-xs text-muted-foreground">{item.description}</p>
          </div>
        </button>
      {/each}
    </div>
  </ScrollArea>
</div>
```

## Props

- `class` - Additional CSS classes
- `orientation` - Scroll orientation ('vertical' | 'horizontal' | 'both')
  - Default: 'vertical'
- `scrollbarVisibility` - When scrollbar is visible ('auto' | 'always' | 'hover')
  - Default: 'auto'

## Common Patterns

### File Explorer
```svelte
<script>
  import { Folder, File } from "phosphor-svelte";
</script>

<ScrollArea class="h-[400px] w-[250px] rounded-md border">
  <div class="p-2">
    {#each fileTree as item}
      <button
        class="flex w-full items-center gap-2 rounded-md p-2 hover:bg-accent"
      >
        {#if item.type === 'folder'}
          <Folder class="h-4 w-4" />
        {:else}
          <File class="h-4 w-4" />
        {/if}
        <span class="text-sm">{item.name}</span>
      </button>
    {/each}
  </div>
</ScrollArea>
```

### Terminal Output
```svelte
<div class="rounded-lg bg-black p-4">
  <div class="mb-2 flex items-center gap-2">
    <div class="h-3 w-3 rounded-full bg-red-500" />
    <div class="h-3 w-3 rounded-full bg-yellow-500" />
    <div class="h-3 w-3 rounded-full bg-green-500" />
  </div>
  <ScrollArea class="h-[300px]">
    <pre class="text-sm text-green-400">
      <code>{terminalOutput}</code>
    </pre>
  </ScrollArea>
</div>
```

### Data Table
```svelte
<div class="rounded-md border">
  <ScrollArea class="h-[400px]">
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Name</TableHead>
          <TableHead>Email</TableHead>
          <TableHead>Role</TableHead>
          <TableHead>Status</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {#each users as user}
          <TableRow>
            <TableCell>{user.name}</TableCell>
            <TableCell>{user.email}</TableCell>
            <TableCell>{user.role}</TableCell>
            <TableCell>
              <Badge variant={user.active ? "default" : "secondary"}>
                {user.active ? "Active" : "Inactive"}
              </Badge>
            </TableCell>
          </TableRow>
        {/each}
      </TableBody>
    </Table>
  </ScrollArea>
</div>
```

## Documentation

- [Official Scroll Area Documentation](https://www.shadcn-svelte.com/docs/components/scroll-area)
- [Bits UI Scroll Area](https://bits-ui.com/docs/components/scroll-area)
