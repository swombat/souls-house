# Button Component

## Installation

```bash
bunx shadcn-svelte@latest add button
```

## Usage

```svelte
<script>
  import { Button } from "$lib/components/ui/button";
</script>

<Button>Click me</Button>
<Button variant="secondary">Secondary</Button>
<Button variant="destructive">Delete</Button>
<Button variant="outline">Outline</Button>
<Button variant="ghost">Ghost</Button>
<Button variant="link">Link</Button>

<!-- With icon -->
<Button>
  <Icon name="mail" class="mr-2 h-4 w-4" />
  Login with Email
</Button>

<!-- Disabled state -->
<Button disabled>Disabled</Button>

<!-- Loading state -->
<Button disabled>
  <Loader class="mr-2 h-4 w-4 animate-spin" />
  Please wait
</Button>
```

## Variants

- `default` - Primary button style
- `secondary` - Secondary button style
- `destructive` - Destructive action button
- `outline` - Outlined button
- `ghost` - Minimal button style
- `link` - Button that looks like a link

## Sizes

```svelte
<Button size="sm">Small</Button>
<Button size="default">Default</Button>
<Button size="lg">Large</Button>
<Button size="icon">🔍</Button>
```

## Props

- `variant` - Button variant style
- `size` - Button size
- `disabled` - Disable button interaction
- `class` - Additional CSS classes
- `href` - Makes button a link

## Documentation

- [Official Button Documentation](https://www.shadcn-svelte.com/docs/components/button)
