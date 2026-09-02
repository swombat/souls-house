# Alert Dialog Component

## Installation

```bash
bunx shadcn-svelte@latest add alert-dialog
```

## Usage

```svelte
<script>
  import * as AlertDialog from "$lib/components/ui/alert-dialog";
  import { Button } from "$lib/components/ui/button";
</script>

<!-- Basic alert dialog -->
<AlertDialog.Root>
  <AlertDialog.Trigger asChild>
    <Button variant="destructive">Delete Account</Button>
  </AlertDialog.Trigger>
  <AlertDialog.Content>
    <AlertDialog.Header>
      <AlertDialog.Title>Are you absolutely sure?</AlertDialog.Title>
      <AlertDialog.Description>
        This action cannot be undone. This will permanently delete your
        account and remove your data from our servers.
      </AlertDialog.Description>
    </AlertDialog.Header>
    <AlertDialog.Footer>
      <AlertDialog.Cancel>Cancel</AlertDialog.Cancel>
      <AlertDialog.Action>Continue</AlertDialog.Action>
    </AlertDialog.Footer>
  </AlertDialog.Content>
</AlertDialog.Root>

<!-- Controlled alert dialog -->
<script>
  let open = false;
  
  function handleDelete() {
    // Perform deletion
    console.log("Deleting...");
    open = false;
  }
</script>

<Button variant="destructive" on:click={() => open = true}>
  Delete
</Button>

<AlertDialog.Root bind:open>
  <AlertDialog.Content>
    <AlertDialog.Header>
      <AlertDialog.Title>Confirm Deletion</AlertDialog.Title>
      <AlertDialog.Description>
        Are you sure you want to delete this item?
      </AlertDialog.Description>
    </AlertDialog.Header>
    <AlertDialog.Footer>
      <AlertDialog.Cancel>Cancel</AlertDialog.Cancel>
      <AlertDialog.Action on:click={handleDelete}>
        Delete
      </AlertDialog.Action>
    </AlertDialog.Footer>
  </AlertDialog.Content>
</AlertDialog.Root>
```

## Components

- `AlertDialog.Root` - Root container
- `AlertDialog.Trigger` - Trigger element
- `AlertDialog.Content` - Dialog content
- `AlertDialog.Header` - Header section
- `AlertDialog.Title` - Dialog title
- `AlertDialog.Description` - Dialog description
- `AlertDialog.Footer` - Footer section
- `AlertDialog.Action` - Confirm action button
- `AlertDialog.Cancel` - Cancel button

## Props

### AlertDialog.Root
- `open` - Controlled open state
- `onOpenChange` - Callback when open state changes

## Documentation

- [Official Alert Dialog Documentation](https://www.shadcn-svelte.com/docs/components/alert-dialog)
- [Bits UI Alert Dialog](https://bits-ui.com/docs/components/alert-dialog)
