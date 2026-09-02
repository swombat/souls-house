# Dialog Component

## Installation

```bash
bunx shadcn-svelte@latest add dialog
```

## Usage

```svelte
<script>
  import * as Dialog from "$lib/components/ui/dialog";
  import { Button } from "$lib/components/ui/button";
  import { Input } from "$lib/components/ui/input";
  import { Label } from "$lib/components/ui/label";
  
  let open = false;
</script>

<!-- Basic dialog -->
<Dialog.Root>
  <Dialog.Trigger asChild>
    <Button variant="outline">Edit Profile</Button>
  </Dialog.Trigger>
  <Dialog.Content class="sm:max-w-[425px]">
    <Dialog.Header>
      <Dialog.Title>Edit profile</Dialog.Title>
      <Dialog.Description>
        Make changes to your profile here. Click save when you're done.
      </Dialog.Description>
    </Dialog.Header>
    <div class="grid gap-4 py-4">
      <div class="grid grid-cols-4 items-center gap-4">
        <Label for="name" class="text-right">Name</Label>
        <Input id="name" value="John Doe" class="col-span-3" />
      </div>
      <div class="grid grid-cols-4 items-center gap-4">
        <Label for="username" class="text-right">Username</Label>
        <Input id="username" value="@johndoe" class="col-span-3" />
      </div>
    </div>
    <Dialog.Footer>
      <Button type="submit">Save changes</Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>

<!-- Controlled dialog -->
<Button on:click={() => open = true}>Open Dialog</Button>

<Dialog.Root bind:open>
  <Dialog.Content>
    <Dialog.Header>
      <Dialog.Title>Are you sure?</Dialog.Title>
      <Dialog.Description>
        This action cannot be undone.
      </Dialog.Description>
    </Dialog.Header>
    <Dialog.Footer>
      <Button variant="outline" on:click={() => open = false}>
        Cancel
      </Button>
      <Button on:click={handleConfirm}>Continue</Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>

<!-- Custom close button -->
<Dialog.Root>
  <Dialog.Trigger asChild>
    <Button>Open</Button>
  </Dialog.Trigger>
  <Dialog.Content class="sm:max-w-md">
    <Dialog.Header>
      <Dialog.Title>Share link</Dialog.Title>
      <Dialog.Description>
        Anyone who has this link will be able to view this.
      </Dialog.Description>
    </Dialog.Header>
    <div class="flex items-center space-x-2">
      <div class="grid flex-1 gap-2">
        <Label for="link" class="sr-only">Link</Label>
        <Input
          id="link"
          value="https://example.com/link/to/share"
          readOnly
        />
      </div>
      <Button type="submit" size="sm" class="px-3">
        <Copy class="h-4 w-4" />
      </Button>
    </div>
    <Dialog.Footer class="sm:justify-start">
      <Dialog.Close asChild>
        <Button type="button" variant="secondary">
          Close
        </Button>
      </Dialog.Close>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>

<!-- Scrollable content -->
<Dialog.Root>
  <Dialog.Trigger asChild>
    <Button>Terms of Service</Button>
  </Dialog.Trigger>
  <Dialog.Content class="max-h-[80vh]">
    <Dialog.Header>
      <Dialog.Title>Terms of Service</Dialog.Title>
    </Dialog.Header>
    <ScrollArea class="h-[60vh] pr-4">
      <div class="space-y-4">
        <!-- Long content here -->
      </div>
    </ScrollArea>
    <Dialog.Footer>
      <Button>Accept</Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
```

## Components

- `Dialog.Root` - Dialog container
- `Dialog.Trigger` - Element that opens dialog
- `Dialog.Content` - Dialog content container
- `Dialog.Header` - Dialog header section
- `Dialog.Title` - Dialog title
- `Dialog.Description` - Dialog description
- `Dialog.Footer` - Dialog footer section
- `Dialog.Close` - Close button

## Props

### Dialog.Root
- `open` - Controlled open state
- `onOpenChange` - Callback when open state changes

### Dialog.Content
- `class` - Additional CSS classes
- Common width classes:
  - `sm:max-w-[425px]` - Small
  - `sm:max-w-md` - Medium
  - `sm:max-w-lg` - Large
  - `sm:max-w-xl` - Extra large

## Patterns

### Confirmation Dialog
```svelte
<script>
  let deleteDialogOpen = false;
  
  async function handleDelete() {
    // Perform deletion
    await deleteItem();
    deleteDialogOpen = false;
  }
</script>

<Dialog.Root bind:open={deleteDialogOpen}>
  <Dialog.Trigger asChild>
    <Button variant="destructive">Delete</Button>
  </Dialog.Trigger>
  <Dialog.Content>
    <Dialog.Header>
      <Dialog.Title>Are you absolutely sure?</Dialog.Title>
      <Dialog.Description>
        This action cannot be undone. This will permanently delete your
        account and remove your data from our servers.
      </Dialog.Description>
    </Dialog.Header>
    <Dialog.Footer>
      <Button 
        variant="outline" 
        on:click={() => deleteDialogOpen = false}
      >
        Cancel
      </Button>
      <Button 
        variant="destructive" 
        on:click={handleDelete}
      >
        Delete
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
```

## Documentation

- [Official Dialog Documentation](https://www.shadcn-svelte.com/docs/components/dialog)
- [Bits UI Dialog](https://bits-ui.com/docs/components/dialog)
