# Card Component

## Installation

```bash
bunx shadcn-svelte@latest add card
```

## Usage

```svelte
<script>
  import * as Card from "$lib/components/ui/card";
  import { Button } from "$lib/components/ui/button";
</script>

<!-- Basic card -->
<Card.Root>
  <Card.Header>
    <Card.Title>Card Title</Card.Title>
    <Card.Description>Card description goes here.</Card.Description>
  </Card.Header>
  <Card.Content>
    <p>Card content goes here.</p>
  </Card.Content>
  <Card.Footer>
    <Button>Action</Button>
  </Card.Footer>
</Card.Root>

<!-- Simple card -->
<Card.Root class="w-[350px]">
  <Card.Header>
    <Card.Title>Create project</Card.Title>
    <Card.Description>Deploy your new project in one-click.</Card.Description>
  </Card.Header>
  <Card.Content>
    <form>
      <div class="grid w-full items-center gap-4">
        <div class="flex flex-col space-y-1.5">
          <Label for="name">Name</Label>
          <Input id="name" placeholder="Name of your project" />
        </div>
      </div>
    </form>
  </Card.Content>
  <Card.Footer class="flex justify-between">
    <Button variant="outline">Cancel</Button>
    <Button>Deploy</Button>
  </Card.Footer>
</Card.Root>

<!-- Profile card -->
<Card.Root class="w-[380px]">
  <Card.Header>
    <div class="flex items-center space-x-4">
      <Avatar>
        <AvatarImage src="/avatar.jpg" alt="User" />
        <AvatarFallback>JD</AvatarFallback>
      </Avatar>
      <div>
        <Card.Title>John Doe</Card.Title>
        <Card.Description>Software Engineer</Card.Description>
      </div>
    </div>
  </Card.Header>
  <Card.Content>
    <div class="grid gap-2">
      <div class="flex items-center gap-2">
        <Mail class="h-4 w-4 opacity-70" />
        <span class="text-sm text-muted-foreground">john@example.com</span>
      </div>
      <div class="flex items-center gap-2">
        <Phone class="h-4 w-4 opacity-70" />
        <span class="text-sm text-muted-foreground">+1 (555) 123-4567</span>
      </div>
    </div>
  </Card.Content>
</Card.Root>

<!-- Stats card -->
<Card.Root>
  <Card.Header class="flex flex-row items-center justify-between space-y-0 pb-2">
    <Card.Title class="text-sm font-medium">Total Revenue</Card.Title>
    <DollarSign class="h-4 w-4 text-muted-foreground" />
  </Card.Header>
  <Card.Content>
    <div class="text-2xl font-bold">$45,231.89</div>
    <p class="text-xs text-muted-foreground">
      +20.1% from last month
    </p>
  </Card.Content>
</Card.Root>

<!-- No footer card -->
<Card.Root>
  <Card.Header>
    <Card.Title>Notifications</Card.Title>
  </Card.Header>
  <Card.Content class="grid gap-4">
    <div class="flex items-center space-x-4">
      <Bell class="h-4 w-4" />
      <div class="flex-1 space-y-1">
        <p class="text-sm font-medium">Push Notifications</p>
        <p class="text-sm text-muted-foreground">
          Receive push notifications
        </p>
      </div>
      <Switch />
    </div>
  </Card.Content>
</Card.Root>
```

## Components

- `Card.Root` - Card container
- `Card.Header` - Card header section
- `Card.Title` - Card title
- `Card.Description` - Card description/subtitle
- `Card.Content` - Main card content
- `Card.Footer` - Card footer section

## Props

All card components accept:
- `class` - Additional CSS classes
- Standard HTML attributes

## Styling Variants

```svelte
<!-- Bordered card -->
<Card.Root class="border-2">
  <!-- content -->
</Card.Root>

<!-- Shadowed card -->
<Card.Root class="shadow-lg">
  <!-- content -->
</Card.Root>

<!-- Colored card -->
<Card.Root class="bg-primary text-primary-foreground">
  <!-- content -->
</Card.Root>
```

## Documentation

- [Official Card Documentation](https://www.shadcn-svelte.com/docs/components/card)
