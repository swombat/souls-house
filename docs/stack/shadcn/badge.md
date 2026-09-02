# Badge Component

## Installation

```bash
bunx shadcn-svelte@latest add badge
```

## Usage

```svelte
<script>
  import { Badge } from "$lib/components/ui/badge";
</script>

<Badge>Default</Badge>
<Badge variant="secondary">Secondary</Badge>
<Badge variant="outline">Outline</Badge>
<Badge variant="destructive">Destructive</Badge>
```

## Variants

```svelte
<Badge variant="default">Default Badge</Badge>
<Badge variant="secondary">Secondary Badge</Badge>
<Badge variant="outline">Outline Badge</Badge>
<Badge variant="destructive">Destructive Badge</Badge>
```

## Usage Examples

```svelte
<!-- Status indicators -->
<Badge variant="default">Active</Badge>
<Badge variant="secondary">Pending</Badge>
<Badge variant="destructive">Error</Badge>

<!-- Count badges -->
<Badge>12</Badge>
<Badge variant="secondary">New</Badge>

<!-- With icons -->
<Badge>
  <Star class="mr-1 h-3 w-3" />
  Featured
</Badge>
```

## Props

- `variant` - Badge variant ('default', 'secondary', 'outline', 'destructive')
- `class` - Additional CSS classes

## Documentation

- [Official Badge Documentation](https://www.shadcn-svelte.com/docs/components/badge)
