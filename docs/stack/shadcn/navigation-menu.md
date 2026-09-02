# Navigation Menu Component

## Installation

```bash
bunx shadcn-svelte@latest add navigation-menu
```

## Usage

```svelte
<script>
  import * as NavigationMenu from "$lib/components/ui/navigation-menu";
</script>

<!-- Basic navigation menu -->
<NavigationMenu.Root>
  <NavigationMenu.List>
    <NavigationMenu.Item>
      <NavigationMenu.Trigger>Getting started</NavigationMenu.Trigger>
      <NavigationMenu.Content>
        <ul class="grid gap-3 p-6 md:w-[400px] lg:w-[500px] lg:grid-cols-[.75fr_1fr]">
          <li class="row-span-3">
            <NavigationMenu.Link asChild>
              <a
                class="flex h-full w-full select-none flex-col justify-end rounded-md bg-gradient-to-b from-muted/50 to-muted p-6 no-underline outline-none focus:shadow-md"
                href="/"
              >
                <div class="mb-2 mt-4 text-lg font-medium">
                  shadcn/ui
                </div>
                <p class="text-sm leading-tight text-muted-foreground">
                  Beautifully designed components built with Radix UI and
                  Tailwind CSS.
                </p>
              </a>
            </NavigationMenu.Link>
          </li>
          <ListItem href="/docs" title="Introduction">
            Re-usable components built using Radix UI and Tailwind CSS.
          </ListItem>
          <ListItem href="/docs/installation" title="Installation">
            How to install dependencies and structure your app.
          </ListItem>
          <ListItem href="/docs/primitives/typography" title="Typography">
            Styles for headings, paragraphs, lists...etc
          </ListItem>
        </ul>
      </NavigationMenu.Content>
    </NavigationMenu.Item>

    <NavigationMenu.Item>
      <NavigationMenu.Trigger>Components</NavigationMenu.Trigger>
      <NavigationMenu.Content>
        <ul class="grid w-[400px] gap-3 p-4 md:w-[500px] md:grid-cols-2 lg:w-[600px]">
          {#each components as component}
            <ListItem
              title={component.title}
              href={component.href}
            >
              {component.description}
            </ListItem>
          {/each}
        </ul>
      </NavigationMenu.Content>
    </NavigationMenu.Item>

    <NavigationMenu.Item>
      <NavigationMenu.Link href="/docs" class="group inline-flex h-10 w-max items-center justify-center rounded-md bg-background px-4 py-2 text-sm font-medium transition-colors hover:bg-accent hover:text-accent-foreground focus:bg-accent focus:text-accent-foreground focus:outline-none disabled:pointer-events-none disabled:opacity-50 data-[active]:bg-accent/50 data-[state=open]:bg-accent/50">
        Documentation
      </NavigationMenu.Link>
    </NavigationMenu.Item>

    <NavigationMenu.Indicator class="top-full z-[1] flex h-1.5 items-end justify-center overflow-hidden data-[state=visible]:animate-in data-[state=hidden]:animate-out data-[state=hidden]:fade-out data-[state=visible]:fade-in">
      <div class="relative top-[60%] h-2 w-2 rotate-45 rounded-tl-sm bg-border shadow-md" />
    </NavigationMenu.Indicator>
  </NavigationMenu.List>

  <div class="absolute left-0 top-full flex justify-center">
    <NavigationMenu.Viewport class="origin-top-center relative mt-1.5 h-[var(--radix-navigation-menu-viewport-height)] w-full overflow-hidden rounded-md border bg-popover text-popover-foreground shadow-lg data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-90 md:w-[var(--radix-navigation-menu-viewport-width)]" />
  </div>
</NavigationMenu.Root>

<!-- Simple navigation menu -->
<NavigationMenu.Root orientation="horizontal">
  <NavigationMenu.List>
    <NavigationMenu.Item>
      <NavigationMenu.Link href="/home">
        Home
      </NavigationMenu.Link>
    </NavigationMenu.Item>
    
    <NavigationMenu.Item>
      <NavigationMenu.Trigger>
        Products
      </NavigationMenu.Trigger>
      <NavigationMenu.Content>
        <div class="grid gap-3 p-4 w-[400px]">
          <NavigationMenu.Link href="/products/web">
            Web Applications
          </NavigationMenu.Link>
          <NavigationMenu.Link href="/products/mobile">
            Mobile Apps
          </NavigationMenu.Link>
          <NavigationMenu.Link href="/products/desktop">
            Desktop Software
          </NavigationMenu.Link>
        </div>
      </NavigationMenu.Content>
    </NavigationMenu.Item>
    
    <NavigationMenu.Item>
      <NavigationMenu.Link href="/about">
        About
      </NavigationMenu.Link>
    </NavigationMenu.Item>
    
    <NavigationMenu.Item>
      <NavigationMenu.Link href="/contact">
        Contact
      </NavigationMenu.Link>
    </NavigationMenu.Item>
  </NavigationMenu.List>
</NavigationMenu.Root>

<!-- Vertical navigation menu -->
<NavigationMenu.Root orientation="vertical" class="relative z-10 flex max-w-max flex-col items-start">
  <NavigationMenu.List class="group flex flex-col items-start justify-center gap-1">
    <NavigationMenu.Item>
      <NavigationMenu.Trigger class="group inline-flex w-full items-center justify-between rounded-md px-4 py-2 text-sm font-medium transition-colors hover:bg-accent hover:text-accent-foreground focus:bg-accent focus:text-accent-foreground focus:outline-none data-[state=open]:bg-accent/50">
        Account
        <ChevronDown class="relative top-[1px] ml-1 h-3 w-3 transition duration-200 group-data-[state=open]:rotate-180" />
      </NavigationMenu.Trigger>
      <NavigationMenu.Content class="left-0 top-0 w-full data-[motion^=from-]:animate-in data-[motion^=to-]:animate-out data-[motion^=from-]:fade-in data-[motion^=to-]:fade-out data-[motion=from-end]:slide-in-from-right-52 data-[motion=from-start]:slide-in-from-left-52 data-[motion=to-end]:slide-out-to-right-52 data-[motion=to-start]:slide-out-to-left-52">
        <ul class="grid gap-1 p-4 w-[400px]">
          <li>
            <NavigationMenu.Link href="/account/profile">
              Profile Settings
            </NavigationMenu.Link>
          </li>
          <li>
            <NavigationMenu.Link href="/account/billing">
              Billing
            </NavigationMenu.Link>
          </li>
          <li>
            <NavigationMenu.Link href="/account/security">
              Security
            </NavigationMenu.Link>
          </li>
        </ul>
      </NavigationMenu.Content>
    </NavigationMenu.Item>
  </NavigationMenu.List>
</NavigationMenu.Root>

<!-- Helper component for list items -->
<script>
  const ListItem = {
    // Define as Svelte component
  };
  
  const components = [
    {
      title: "Alert Dialog",
      href: "/docs/primitives/alert-dialog",
      description: "A modal dialog that interrupts the user with important content and expects a response."
    },
    {
      title: "Hover Card",
      href: "/docs/primitives/hover-card",
      description: "For sighted users to preview content available behind a link."
    },
    {
      title: "Progress",
      href: "/docs/primitives/progress",
      description: "Displays an indicator showing the completion progress of a task."
    },
    {
      title: "Scroll-area",
      href: "/docs/primitives/scroll-area",
      description: "Visually or semantically separates content."
    }
  ];
</script>
```

## Components

- `NavigationMenu.Root` - Navigation menu container
- `NavigationMenu.List` - List container for navigation items
- `NavigationMenu.Item` - Individual navigation item
- `NavigationMenu.Trigger` - Button that opens submenu
- `NavigationMenu.Content` - Submenu content container
- `NavigationMenu.Link` - Navigation link (internal or external)
- `NavigationMenu.Indicator` - Visual indicator for active item
- `NavigationMenu.Viewport` - Container for submenu content

## Props

### NavigationMenu.Root
- `value` - Controlled value of open item
- `onValueChange` - Callback when value changes
- `dir` - Text direction (`"ltr"` | `"rtl"`)
- `orientation` - Menu orientation (`"horizontal"` | `"vertical"`)
- `class` - Additional CSS classes

### NavigationMenu.Trigger
- `class` - Additional CSS classes

### NavigationMenu.Content
- `class` - Additional CSS classes

### NavigationMenu.Link
- `href` - Link destination
- `active` - Whether link is active
- `class` - Additional CSS classes

## Orientation

### Horizontal (default)
```svelte
<NavigationMenu.Root orientation="horizontal">
  <!-- Horizontal navigation bar -->
</NavigationMenu.Root>
```

### Vertical
```svelte
<NavigationMenu.Root orientation="vertical">
  <!-- Vertical sidebar navigation -->
</NavigationMenu.Root>
```

## Patterns

### Navigation with icons
```svelte
<NavigationMenu.Item>
  <NavigationMenu.Link href="/dashboard" class="flex items-center gap-2">
    <Home class="h-4 w-4" />
    Dashboard
  </NavigationMenu.Link>
</NavigationMenu.Item>
```

### Multi-level navigation
```svelte
<NavigationMenu.Item>
  <NavigationMenu.Trigger>Products</NavigationMenu.Trigger>
  <NavigationMenu.Content>
    <NavigationMenu.Sub>
      <NavigationMenu.SubTrigger>Web Development</NavigationMenu.SubTrigger>
      <NavigationMenu.SubContent>
        <NavigationMenu.Link href="/products/web/frontend">
          Frontend
        </NavigationMenu.Link>
        <NavigationMenu.Link href="/products/web/backend">
          Backend
        </NavigationMenu.Link>
      </NavigationMenu.SubContent>
    </NavigationMenu.Sub>
  </NavigationMenu.Content>
</NavigationMenu.Item>
```

### Active link styling
```svelte
<script>
  import { page } from '$app/stores';
  
  $: isActive = (href) => $page.url.pathname === href;
</script>

<NavigationMenu.Link 
  href="/dashboard"
  class={isActive('/dashboard') ? 'bg-accent text-accent-foreground' : ''}
>
  Dashboard
</NavigationMenu.Link>
```

## Best Practices

- Keep navigation structure simple and intuitive
- Use clear, descriptive labels
- Indicate active/current page
- Consider mobile responsiveness
- Group related items in submenus
- Use consistent spacing and styling

## Accessibility

- Proper ARIA roles and properties
- Keyboard navigation support
- Focus management
- Screen reader friendly

## Documentation

- [Official Navigation Menu Documentation](https://www.shadcn-svelte.com/docs/components/navigation-menu)
- [Bits UI Navigation Menu](https://bits-ui.com/docs/components/navigation-menu)
