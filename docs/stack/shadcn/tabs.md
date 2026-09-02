# Tabs Component

## Installation

```bash
bunx shadcn-svelte@latest add tabs
```

## Usage

```svelte
<script>
  import * as Tabs from "$lib/components/ui/tabs";
  import * as Card from "$lib/components/ui/card";
  import { Button } from "$lib/components/ui/button";
  import { Input } from "$lib/components/ui/input";
  import { Label } from "$lib/components/ui/label";
</script>

<!-- Basic tabs -->
<Tabs.Root value="account" class="w-[400px]">
  <Tabs.List>
    <Tabs.Trigger value="account">Account</Tabs.Trigger>
    <Tabs.Trigger value="password">Password</Tabs.Trigger>
  </Tabs.List>
  <Tabs.Content value="account">
    <Card.Root>
      <Card.Header>
        <Card.Title>Account</Card.Title>
        <Card.Description>
          Make changes to your account here.
        </Card.Description>
      </Card.Header>
      <Card.Content class="space-y-2">
        <div class="space-y-1">
          <Label for="name">Name</Label>
          <Input id="name" value="John Doe" />
        </div>
        <div class="space-y-1">
          <Label for="username">Username</Label>
          <Input id="username" value="@johndoe" />
        </div>
      </Card.Content>
      <Card.Footer>
        <Button>Save changes</Button>
      </Card.Footer>
    </Card.Root>
  </Tabs.Content>
  <Tabs.Content value="password">
    <Card.Root>
      <Card.Header>
        <Card.Title>Password</Card.Title>
        <Card.Description>
          Change your password here.
        </Card.Description>
      </Card.Header>
      <Card.Content class="space-y-2">
        <div class="space-y-1">
          <Label for="current">Current password</Label>
          <Input id="current" type="password" />
        </div>
        <div class="space-y-1">
          <Label for="new">New password</Label>
          <Input id="new" type="password" />
        </div>
      </Card.Content>
      <Card.Footer>
        <Button>Save password</Button>
      </Card.Footer>
    </Card.Root>
  </Tabs.Content>
</Tabs.Root>

<!-- Controlled tabs -->
<script>
  let activeTab = "overview";
</script>

<Tabs.Root bind:value={activeTab}>
  <Tabs.List>
    <Tabs.Trigger value="overview">Overview</Tabs.Trigger>
    <Tabs.Trigger value="analytics">Analytics</Tabs.Trigger>
    <Tabs.Trigger value="reports">Reports</Tabs.Trigger>
  </Tabs.List>
  <Tabs.Content value="overview">Overview content</Tabs.Content>
  <Tabs.Content value="analytics">Analytics content</Tabs.Content>
  <Tabs.Content value="reports">Reports content</Tabs.Content>
</Tabs.Root>
```

## Components

- `Tabs.Root` - Root container
- `Tabs.List` - Tab triggers container
- `Tabs.Trigger` - Individual tab trigger
- `Tabs.Content` - Tab panel content

## Props

### Tabs.Root
- `value` - Active tab value
- `orientation` - Tab orientation ('horizontal' | 'vertical')
- `class` - Additional CSS classes

### Tabs.Trigger
- `value` - Tab identifier
- `disabled` - Disable tab

## Documentation

- [Official Tabs Documentation](https://www.shadcn-svelte.com/docs/components/tabs)
- [Bits UI Tabs](https://bits-ui.com/docs/components/tabs)
