# Breadcrumb Component

## Installation

```bash
bunx shadcn-svelte@latest add breadcrumb
```

## Usage

```svelte
<script>
  import * as Breadcrumb from "$lib/components/ui/breadcrumb";
</script>

<!-- Basic breadcrumb -->
<Breadcrumb.Root>
  <Breadcrumb.List>
    <Breadcrumb.Item>
      <Breadcrumb.Link href="/">Home</Breadcrumb.Link>
    </Breadcrumb.Item>
    <Breadcrumb.Separator />
    <Breadcrumb.Item>
      <Breadcrumb.Link href="/components">Components</Breadcrumb.Link>
    </Breadcrumb.Item>
    <Breadcrumb.Separator />
    <Breadcrumb.Item>
      <Breadcrumb.Page>Breadcrumb</Breadcrumb.Page>
    </Breadcrumb.Item>
  </Breadcrumb.List>
</Breadcrumb.Root>

<!-- Breadcrumb with custom separator -->
<Breadcrumb.Root>
  <Breadcrumb.List>
    <Breadcrumb.Item>
      <Breadcrumb.Link href="/">Home</Breadcrumb.Link>
    </Breadcrumb.Item>
    <Breadcrumb.Separator>
      <ChevronRight class="h-4 w-4" />
    </Breadcrumb.Separator>
    <Breadcrumb.Item>
      <Breadcrumb.Link href="/docs">Documentation</Breadcrumb.Link>
    </Breadcrumb.Item>
    <Breadcrumb.Separator>
      <ChevronRight class="h-4 w-4" />
    </Breadcrumb.Separator>
    <Breadcrumb.Item>
      <Breadcrumb.Page>Components</Breadcrumb.Page>
    </Breadcrumb.Item>
  </Breadcrumb.List>
</Breadcrumb.Root>

<!-- Breadcrumb with dropdown -->
<Breadcrumb.Root>
  <Breadcrumb.List>
    <Breadcrumb.Item>
      <Breadcrumb.Link href="/">Home</Breadcrumb.Link>
    </Breadcrumb.Item>
    <Breadcrumb.Separator />
    <Breadcrumb.Item>
      <DropdownMenu.Root>
        <DropdownMenu.Trigger class="flex items-center gap-1">
          <Breadcrumb.Ellipsis class="h-4 w-4" />
          <span class="sr-only">Toggle menu</span>
        </DropdownMenu.Trigger>
        <DropdownMenu.Content align="start">
          <DropdownMenu.Item href="/docs">Documentation</DropdownMenu.Item>
          <DropdownMenu.Item href="/themes">Themes</DropdownMenu.Item>
          <DropdownMenu.Item href="/examples">Examples</DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Root>
    </Breadcrumb.Item>
    <Breadcrumb.Separator />
    <Breadcrumb.Item>
      <Breadcrumb.Link href="/components">Components</Breadcrumb.Link>
    </Breadcrumb.Item>
    <Breadcrumb.Separator />
    <Breadcrumb.Item>
      <Breadcrumb.Page>Breadcrumb</Breadcrumb.Page>
    </Breadcrumb.Item>
  </Breadcrumb.List>
</Breadcrumb.Root>

<!-- Responsive breadcrumb -->
<Breadcrumb.Root>
  <Breadcrumb.List>
    <Breadcrumb.Item>
      <Breadcrumb.Link href="/" class="md:block hidden">
        Home
      </Breadcrumb.Link>
    </Breadcrumb.Item>
    <Breadcrumb.Separator class="md:block hidden" />
    <Breadcrumb.Item>
      <Breadcrumb.Link href="/products">Products</Breadcrumb.Link>
    </Breadcrumb.Item>
    <Breadcrumb.Separator />
    <Breadcrumb.Item>
      <Breadcrumb.Link href="/products/laptops">Laptops</Breadcrumb.Link>
    </Breadcrumb.Item>
    <Breadcrumb.Separator />
    <Breadcrumb.Item>
      <Breadcrumb.Page>Gaming Laptop</Breadcrumb.Page>
    </Breadcrumb.Item>
  </Breadcrumb.List>
</Breadcrumb.Root>

<!-- Breadcrumb with icons -->
<Breadcrumb.Root>
  <Breadcrumb.List>
    <Breadcrumb.Item>
      <Breadcrumb.Link href="/" class="flex items-center gap-2">
        <Home class="h-4 w-4" />
        Home
      </Breadcrumb.Link>
    </Breadcrumb.Item>
    <Breadcrumb.Separator />
    <Breadcrumb.Item>
      <Breadcrumb.Link href="/projects" class="flex items-center gap-2">
        <Folder class="h-4 w-4" />
        Projects
      </Breadcrumb.Link>
    </Breadcrumb.Item>
    <Breadcrumb.Separator />
    <Breadcrumb.Item>
      <Breadcrumb.Page class="flex items-center gap-2">
        <File class="h-4 w-4" />
        project.json
      </Breadcrumb.Page>
    </Breadcrumb.Item>
  </Breadcrumb.List>
</Breadcrumb.Root>
```

## Components

- `Breadcrumb.Root` - Breadcrumb container
- `Breadcrumb.List` - List container for breadcrumb items
- `Breadcrumb.Item` - Individual breadcrumb item
- `Breadcrumb.Link` - Clickable breadcrumb link
- `Breadcrumb.Page` - Current page indicator (non-clickable)
- `Breadcrumb.Separator` - Visual separator between items
- `Breadcrumb.Ellipsis` - Ellipsis for collapsed breadcrumbs

## Props

### Breadcrumb.Root
- `class` - Additional CSS classes

### Breadcrumb.List
- `class` - Additional CSS classes

### Breadcrumb.Item
- `class` - Additional CSS classes

### Breadcrumb.Link
- `href` - Link destination
- `class` - Additional CSS classes

### Breadcrumb.Page
- `class` - Additional CSS classes

### Breadcrumb.Separator
- `class` - Additional CSS classes

## Patterns

### Dynamic breadcrumbs from route
```svelte
<script>
  import { page } from '$app/stores';
  
  $: pathSegments = $page.url.pathname.split('/').filter(Boolean);
</script>

<Breadcrumb.Root>
  <Breadcrumb.List>
    <Breadcrumb.Item>
      <Breadcrumb.Link href="/">Home</Breadcrumb.Link>
    </Breadcrumb.Item>
    
    {#each pathSegments as segment, i}
      <Breadcrumb.Separator />
      <Breadcrumb.Item>
        {#if i === pathSegments.length - 1}
          <Breadcrumb.Page>
            {segment.charAt(0).toUpperCase() + segment.slice(1)}
          </Breadcrumb.Page>
        {:else}
          <Breadcrumb.Link href="/{pathSegments.slice(0, i + 1).join('/')}">
            {segment.charAt(0).toUpperCase() + segment.slice(1)}
          </Breadcrumb.Link>
        {/if}
      </Breadcrumb.Item>
    {/each}
  </Breadcrumb.List>
</Breadcrumb.Root>
```

### Breadcrumb with truncation
```svelte
<Breadcrumb.Root>
  <Breadcrumb.List>
    <Breadcrumb.Item>
      <Breadcrumb.Link href="/">Home</Breadcrumb.Link>
    </Breadcrumb.Item>
    <Breadcrumb.Separator />
    <Breadcrumb.Item>
      <Breadcrumb.Ellipsis />
    </Breadcrumb.Item>
    <Breadcrumb.Separator />
    <Breadcrumb.Item>
      <Breadcrumb.Link href="/parent">Parent</Breadcrumb.Link>
    </Breadcrumb.Item>
    <Breadcrumb.Separator />
    <Breadcrumb.Item>
      <Breadcrumb.Page>Current Page</Breadcrumb.Page>
    </Breadcrumb.Item>
  </Breadcrumb.List>
</Breadcrumb.Root>
```

## Best Practices

- Always include "Home" as the first breadcrumb
- Use `Breadcrumb.Page` for the current page (non-clickable)
- Keep breadcrumb labels concise and descriptive
- Consider responsive behavior on mobile devices
- Use ellipsis for long breadcrumb trails

## Accessibility

- Uses proper ARIA navigation landmark
- Screen reader friendly with semantic HTML
- Keyboard navigation support

## Documentation

- [Official Breadcrumb Documentation](https://www.shadcn-svelte.com/docs/components/breadcrumb)
