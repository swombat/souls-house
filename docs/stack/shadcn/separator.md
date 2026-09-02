# Separator Component

## Installation

```bash
bunx shadcn-svelte@latest add separator
```

## Usage

```svelte
<script>
  import { Separator } from "$lib/components/ui/separator";
</script>

<!-- Horizontal separator -->
<div>
  <div class="space-y-1">
    <h4 class="text-sm font-medium leading-none">Radix Primitives</h4>
    <p class="text-sm text-muted-foreground">
      An open-source UI component library.
    </p>
  </div>
  <Separator class="my-4" />
  <div class="flex h-5 items-center space-x-4 text-sm">
    <div>Blog</div>
    <Separator orientation="vertical" />
    <div>Docs</div>
    <Separator orientation="vertical" />
    <div>Source</div>
  </div>
</div>

<!-- Vertical separator in navigation -->
<div class="flex h-5 items-center space-x-4">
  <Button variant="link" class="p-0 h-auto">Home</Button>
  <Separator orientation="vertical" />
  <Button variant="link" class="p-0 h-auto">About</Button>
  <Separator orientation="vertical" />
  <Button variant="link" class="p-0 h-auto">Contact</Button>
</div>

<!-- In a form -->
<div class="space-y-4">
  <div>
    <h3 class="text-lg font-medium">Account</h3>
    <p class="text-sm text-muted-foreground">
      Update your account settings.
    </p>
  </div>
  <Separator />
  <div class="space-y-4">
    <div>
      <Label for="name">Name</Label>
      <Input id="name" value="John Doe" />
    </div>
    <div>
      <Label for="email">Email</Label>
      <Input id="email" type="email" value="john@example.com" />
    </div>
  </div>
  <Separator />
  <Button>Save changes</Button>
</div>

<!-- In a card -->
<Card.Root>
  <Card.Header>
    <Card.Title>Team Members</Card.Title>
  </Card.Header>
  <Separator />
  <Card.Content class="pt-6">
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div class="flex items-center space-x-4">
          <Avatar>
            <AvatarImage src="/avatar1.jpg" />
            <AvatarFallback>JD</AvatarFallback>
          </Avatar>
          <div>
            <p class="text-sm font-medium">John Doe</p>
            <p class="text-sm text-muted-foreground">john@example.com</p>
          </div>
        </div>
        <Button variant="outline" size="sm">Remove</Button>
      </div>
      <Separator />
      <div class="flex items-center justify-between">
        <div class="flex items-center space-x-4">
          <Avatar>
            <AvatarImage src="/avatar2.jpg" />
            <AvatarFallback>JS</AvatarFallback>
          </Avatar>
          <div>
            <p class="text-sm font-medium">Jane Smith</p>
            <p class="text-sm text-muted-foreground">jane@example.com</p>
          </div>
        </div>
        <Button variant="outline" size="sm">Remove</Button>
      </div>
    </div>
  </Card.Content>
</Card.Root>

<!-- Custom styles -->
<Separator class="my-8 bg-red-500" />
<Separator class="my-4 h-0.5" />
<Separator class="my-4 bg-gradient-to-r from-transparent via-gray-500 to-transparent" />
```

## Props

- `orientation` - Separator orientation ('horizontal' | 'vertical')
  - Default: 'horizontal'
- `decorative` - Whether the separator is decorative (for accessibility)
  - Default: true
- `class` - Additional CSS classes

## Common Patterns

### Section Divider
```svelte
<div class="space-y-6">
  <section>
    <h2 class="text-2xl font-bold">Section 1</h2>
    <p>Content for section 1</p>
  </section>
  
  <Separator />
  
  <section>
    <h2 class="text-2xl font-bold">Section 2</h2>
    <p>Content for section 2</p>
  </section>
</div>
```

### Toolbar Separator
```svelte
<div class="flex items-center p-2 border rounded-lg">
  <Button variant="ghost" size="icon">
    <Bold class="h-4 w-4" />
  </Button>
  <Button variant="ghost" size="icon">
    <Italic class="h-4 w-4" />
  </Button>
  <Button variant="ghost" size="icon">
    <Underline class="h-4 w-4" />
  </Button>
  
  <Separator orientation="vertical" class="mx-2 h-6" />
  
  <Button variant="ghost" size="icon">
    <AlignLeft class="h-4 w-4" />
  </Button>
  <Button variant="ghost" size="icon">
    <AlignCenter class="h-4 w-4" />
  </Button>
  <Button variant="ghost" size="icon">
    <AlignRight class="h-4 w-4" />
  </Button>
</div>
```

## Documentation

- [Official Separator Documentation](https://www.shadcn-svelte.com/docs/components/separator)
- [Bits UI Separator](https://bits-ui.com/docs/components/separator)
