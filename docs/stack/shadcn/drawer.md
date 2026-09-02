# Drawer Component

## Installation

```bash
bunx shadcn-svelte@latest add drawer
```

## Usage

```svelte
<script>
  import * as Drawer from "$lib/components/ui/drawer";
  import { Button } from "$lib/components/ui/button";
  import { Input } from "$lib/components/ui/input";
  import { Label } from "$lib/components/ui/label";
  
  let open = false;
</script>

<Drawer.Root bind:open>
  <Drawer.Trigger asChild let:builder>
    <Button builders={[builder]}>Open Drawer</Button>
  </Drawer.Trigger>
  <Drawer.Content>
    <Drawer.Header>
      <Drawer.Title>Edit profile</Drawer.Title>
      <Drawer.Description>
        Make changes to your profile here. Click save when you're done.
      </Drawer.Description>
    </Drawer.Header>
    <div class="p-4 pb-0">
      <div class="flex items-center space-x-2">
        <div class="grid flex-1 gap-2">
          <Label for="name">Name</Label>
          <Input id="name" value="Pedro Duarte" />
        </div>
        <div class="grid flex-1 gap-2">
          <Label for="username">Username</Label>
          <Input id="username" value="@peduarte" />
        </div>
      </div>
    </div>
    <Drawer.Footer>
      <Button>Save changes</Button>
      <Drawer.Close asChild let:builder>
        <Button builders={[builder]} variant="outline">Cancel</Button>
      </Drawer.Close>
    </Drawer.Footer>
  </Drawer.Content>
</Drawer.Root>
```

## Responsive Design

```svelte
<script>
  import * as Drawer from "$lib/components/ui/drawer";
  import * as Dialog from "$lib/components/ui/dialog";
  import { Button } from "$lib/components/ui/button";
  import { mediaQuery } from "svelte-legos";
  
  const isDesktop = mediaQuery("(min-width: 768px)");
  let open = false;
</script>

{#if $isDesktop}
  <Dialog.Root bind:open>
    <Dialog.Trigger asChild let:builder>
      <Button builders={[builder]}>Edit Profile</Button>
    </Dialog.Trigger>
    <Dialog.Content class="sm:max-w-[425px]">
      <Dialog.Header>
        <Dialog.Title>Edit profile</Dialog.Title>
        <Dialog.Description>
          Make changes to your profile here.
        </Dialog.Description>
      </Dialog.Header>
      <!-- Profile form -->
    </Dialog.Content>
  </Dialog.Root>
{:else}
  <Drawer.Root bind:open>
    <Drawer.Trigger asChild let:builder>
      <Button builders={[builder]}>Edit Profile</Button>
    </Drawer.Trigger>
    <Drawer.Content>
      <Drawer.Header class="text-left">
        <Drawer.Title>Edit profile</Drawer.Title>
        <Drawer.Description>
          Make changes to your profile here.
        </Drawer.Description>
      </Drawer.Header>
      <!-- Profile form -->
    </Drawer.Content>
  </Drawer.Root>
{/if}
```

## With Scrollable Content

```svelte
<Drawer.Root>
  <Drawer.Trigger asChild let:builder>
    <Button builders={[builder]}>Open</Button>
  </Drawer.Trigger>
  <Drawer.Content class="h-[96%]">
    <Drawer.Header>
      <Drawer.Title>Long Content Example</Drawer.Title>
      <Drawer.Description>
        This drawer contains scrollable content.
      </Drawer.Description>
    </Drawer.Header>
    <div class="overflow-y-auto p-4">
      {#each Array(50) as _, i}
        <p class="py-2">Item {i + 1}</p>
      {/each}
    </div>
    <Drawer.Footer>
      <Drawer.Close asChild let:builder>
        <Button builders={[builder]} variant="outline">Close</Button>
      </Drawer.Close>
    </Drawer.Footer>
  </Drawer.Content>
</Drawer.Root>
```

## Props

### Root
- `open` - Whether the drawer is open
- `onOpenChange` - Callback when open state changes
- `shouldScaleBackground` - Scale background when open
- `snapPoints` - Snap points for drawer height
- `activeSnapPoint` - Currently active snap point
- `dismissible` - Allow dismissing by clicking outside

### Trigger
- `asChild` - Render as a child component

### Content
- `class` - Additional CSS classes

### Header/Footer
- `class` - Additional CSS classes

### Title/Description
- `class` - Additional CSS classes

### Close
- `asChild` - Render as a child component

## Documentation

- [Official Drawer Documentation](https://www.shadcn-svelte.com/docs/components/drawer)
- [Vaul Svelte Documentation](https://github.com/huntabyte/vaul-svelte)
