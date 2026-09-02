# Sonner Component

## Installation

```bash
bunx shadcn-svelte@latest add sonner
```

## Usage

```svelte
<script>
  import { toast, Toaster } from "$lib/components/ui/sonner";
  import { Button } from "$lib/components/ui/button";
</script>

<Button on:click={() => toast("Hello World")}>Show Toast</Button>

<!-- Add to your root layout -->
<Toaster />
```

## Toast Types

```svelte
<script>
  import { toast } from "$lib/components/ui/sonner";
  import { Button } from "$lib/components/ui/button";
</script>

<div class="flex gap-2">
  <Button on:click={() => toast("Default toast")}>
    Default
  </Button>
  
  <Button on:click={() => toast.success("Success toast")}>
    Success
  </Button>
  
  <Button on:click={() => toast.error("Error toast")}>
    Error
  </Button>
  
  <Button on:click={() => toast.warning("Warning toast")}>
    Warning
  </Button>
  
  <Button on:click={() => toast.info("Info toast")}>
    Info
  </Button>
</div>
```

## With Description

```svelte
<Button 
  on:click={() => toast("Event created", {
    description: "Your event has been successfully scheduled"
  })}
>
  Show with description
</Button>
```

## With Actions

```svelte
<Button 
  on:click={() => toast("Friend request sent", {
    action: {
      label: "Undo",
      onClick: () => {
        toast("Friend request cancelled");
      }
    }
  })}
>
  Show with action
</Button>
```

## Loading Toast

```svelte
<script>
  import { toast } from "$lib/components/ui/sonner";
  import { Button } from "$lib/components/ui/button";
  
  async function handleAsyncAction() {
    const toastId = toast.loading("Saving...");
    
    try {
      // Simulate async operation
      await new Promise(resolve => setTimeout(resolve, 2000));
      
      toast.success("Saved successfully!", { id: toastId });
    } catch (error) {
      toast.error("Failed to save", { id: toastId });
    }
  }
</script>

<Button on:click={handleAsyncAction}>
  Save Data
</Button>
```

## Promise Toast

```svelte
<script>
  import { toast } from "$lib/components/ui/sonner";
  import { Button } from "$lib/components/ui/button";
  
  async function mockApiCall() {
    return new Promise((resolve, reject) => {
      setTimeout(() => {
        Math.random() > 0.5 ? resolve("Success!") : reject("Error!");
      }, 2000);
    });
  }
  
  function handlePromise() {
    toast.promise(mockApiCall, {
      loading: "Loading...",
      success: "Data loaded successfully!",
      error: "Failed to load data",
    });
  }
</script>

<Button on:click={handlePromise}>
  Load Data
</Button>
```

## Custom Styling

```svelte
<Button 
  on:click={() => toast("Custom styled toast", {
    className: "bg-purple-500 text-white border-purple-600"
  })}
>
  Custom style
</Button>
```

## Rich Content

```svelte
<script>
  import { toast } from "$lib/components/ui/sonner";
  import { Button } from "$lib/components/ui/button";
  import { Avatar, AvatarImage, AvatarFallback } from "$lib/components/ui/avatar";
  
  function showRichToast() {
    toast.custom(
      // Custom component as JSX string or component
      `<div class="flex items-center gap-3">
        <img src="https://github.com/shadcn.png" alt="Avatar" class="h-10 w-10 rounded-full" />
        <div>
          <p class="font-semibold">New message</p>
          <p class="text-sm text-muted-foreground">From John Doe</p>
        </div>
       </div>`
    );
  }
</script>

<Button on:click={showRichToast}>
  Rich content
</Button>
```

## Configuration

```svelte
<!-- In your root layout -->
<script>
  import { Toaster } from "$lib/components/ui/sonner";
</script>

<Toaster 
  position="top-right"
  expand={false}
  richColors={true}
  closeButton={true}
  toastOptions={{
    duration: 4000,
    className: "my-toast",
  }}
/>
```

## Positioning

```svelte
<!-- Different positions -->
<Toaster position="top-left" />
<Toaster position="top-right" />
<Toaster position="bottom-left" />
<Toaster position="bottom-right" />
<Toaster position="top-center" />
<Toaster position="bottom-center" />
```

## API Reference

### toast()
```javascript
// Basic usage
toast("Message")

// With options
toast("Message", {
  description: "Description",
  action: {
    label: "Action",
    onClick: () => console.log("Action clicked")
  },
  duration: 5000,
  id: "unique-id",
  className: "custom-class"
})

// Type-specific methods
toast.success("Success message")
toast.error("Error message") 
toast.warning("Warning message")
toast.info("Info message")
toast.loading("Loading message")

// Promise handling
toast.promise(promise, {
  loading: "Loading...",
  success: "Success!",
  error: "Error!"
})

// Custom content
toast.custom(customComponent)

// Dismiss toasts
toast.dismiss(toastId) // Dismiss specific
toast.dismiss() // Dismiss all
```

### Toaster Props
- `position` - Toast position
- `expand` - Expand toasts on hover
- `richColors` - Use rich colors for different types
- `closeButton` - Show close button
- `toastOptions` - Default options for all toasts
- `theme` - Theme ('light', 'dark', 'system')
- `className` - Additional CSS classes
- `offset` - Offset from viewport edge

## Documentation

- [Official Sonner Documentation](https://www.shadcn-svelte.com/docs/components/sonner)
- [Sonner Library Documentation](https://sonner.emilkowal.ski/)
