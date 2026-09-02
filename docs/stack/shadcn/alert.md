# Alert Component

## Installation

```bash
bunx shadcn-svelte@latest add alert
```

## Usage

```svelte
<script>
  import { Alert, AlertDescription, AlertTitle } from "$lib/components/ui/alert";
  import { Terminal } from "phosphor-svelte";
</script>

<Alert>
  <Terminal class="h-4 w-4" />
  <AlertTitle>Heads up!</AlertTitle>
  <AlertDescription>
    You can add components and dependencies to your app using the CLI.
  </AlertDescription>
</Alert>
```

## Variants

```svelte
<Alert variant="default">
  <AlertTitle>Default Alert</AlertTitle>
  <AlertDescription>
    This is a default alert with neutral styling.
  </AlertDescription>
</Alert>

<Alert variant="destructive">
  <AlertTitle>Error</AlertTitle>
  <AlertDescription>
    This is a destructive alert for error messages.
  </AlertDescription>
</Alert>
```

## Without Title

```svelte
<Alert>
  <Terminal class="h-4 w-4" />
  <AlertDescription>
    Your message has been sent successfully.
  </AlertDescription>
</Alert>
```

## Props

### Alert
- `variant` - 'default' or 'destructive'
- `class` - Additional CSS classes

### AlertTitle
- `class` - Additional CSS classes

### AlertDescription
- `class` - Additional CSS classes

## Documentation

- [Official Alert Documentation](https://www.shadcn-svelte.com/docs/components/alert)
