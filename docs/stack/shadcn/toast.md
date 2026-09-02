# Toast Component

## Installation

```bash
bunx shadcn-svelte@latest add toast
```

## Usage

```svelte
<script>
  import { toast } from "$lib/components/ui/toast";
  import { Button } from "$lib/components/ui/button";
  import { ToastAction } from "$lib/components/ui/toast";
</script>

<Button 
  on:click={() => {
    toast({
      title: "Scheduled: Catch up",
      description: "Friday, February 10, 2023 at 5:57 PM",
    });
  }}
>
  Show Toast
</Button>
```

## Simple Toast

```svelte
<Button 
  on:click={() => {
    toast({
      description: "Your message has been sent.",
    });
  }}
>
  Show Toast
</Button>
```

## With Title and Description

```svelte
<Button 
  on:click={() => {
    toast({
      title: "Uh oh! Something went wrong.",
      description: "There was a problem with your request.",
    });
  }}
>
  Show Toast
</Button>
```

## With Action

```svelte
<Button 
  on:click={() => {
    toast({
      title: "Uh oh! Something went wrong.",
      description: "There was a problem with your request.",
      action: ToastAction({ altText: "Try again" }, "Try again"),
    });
  }}
>
  Show Toast
</Button>
```

## Destructive Toast

```svelte
<Button 
  variant="destructive"
  on:click={() => {
    toast({
      variant: "destructive",
      title: "Uh oh! Something went wrong.",
      description: "There was a problem with your request.",
      action: ToastAction({ altText: "Try again" }, "Try again"),
    });
  }}
>
  Show Destructive Toast
</Button>
```

## Toast Variants

```svelte
<div class="flex gap-2">
  <Button 
    on:click={() => {
      toast({
        title: "Default toast",
        description: "This is a default toast message.",
      });
    }}
  >
    Default
  </Button>
  
  <Button 
    on:click={() => {
      toast({
        variant: "destructive",
        title: "Error occurred",
        description: "Something went wrong with your request.",
      });
    }}
  >
    Destructive
  </Button>
</div>
```

## Form Integration

```svelte
<script>
  import { toast } from "$lib/components/ui/toast";
  import { Button } from "$lib/components/ui/button";
  import { Input } from "$lib/components/ui/input";
  import { Label } from "$lib/components/ui/label";
  
  let email = "";
  let isLoading = false;
  
  async function handleSubmit() {
    if (!email) {
      toast({
        variant: "destructive",
        title: "Error",
        description: "Please enter your email address.",
      });
      return;
    }
    
    isLoading = true;
    
    try {
      const response = await fetch("/api/subscribe", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email }),
      });
      
      if (response.ok) {
        toast({
          title: "Success!",
          description: "You've been subscribed to our newsletter.",
        });
        email = "";
      } else {
        throw new Error("Subscription failed");
      }
    } catch (error) {
      toast({
        variant: "destructive",
        title: "Subscription failed",
        description: "Please try again later.",
      });
    } finally {
      isLoading = false;
    }
  }
</script>

<div class="space-y-4">
  <div class="space-y-2">
    <Label for="email">Email</Label>
    <Input 
      id="email" 
      type="email" 
      placeholder="Enter your email"
      bind:value={email}
    />
  </div>
  
  <Button 
    on:click={handleSubmit}
    disabled={isLoading}
    class="w-full"
  >
    {isLoading ? "Subscribing..." : "Subscribe"}
  </Button>
</div>
```

## Custom Duration

```svelte
<Button 
  on:click={() => {
    toast({
      title: "Custom duration",
      description: "This toast will disappear after 10 seconds.",
      duration: 10000,
    });
  }}
>
  Long Duration Toast
</Button>
```

## Persistent Toast

```svelte
<Button 
  on:click={() => {
    toast({
      title: "Persistent toast",
      description: "This toast won't disappear automatically.",
      duration: Infinity,
    });
  }}
>
  Persistent Toast
</Button>
```

## Setup in Root Layout

```svelte
<!-- src/app.html or root layout -->
<script>
  import { Toaster } from "$lib/components/ui/toast";
</script>

<!-- Your app content -->
<main>
  <slot />
</main>

<!-- Toast container -->
<Toaster />
```

## API Reference

### toast()
```javascript
toast({
  title: "Title",                    // Toast title
  description: "Description",        // Toast description  
  variant: "default" | "destructive", // Toast variant
  action: ToastAction,               // Action button
  duration: 5000,                    // Duration in milliseconds
  id: "unique-id",                   // Custom ID
})
```

### ToastAction
```svelte
<script>
  import { ToastAction } from "$lib/components/ui/toast";
</script>

{ToastAction({ 
  altText: "Action description", 
  onclick: () => console.log("Action clicked")
}, "Button text")}
```

### Props

#### Toast
- `variant` - Toast variant ('default' or 'destructive')
- `title` - Toast title
- `description` - Toast description
- `action` - Action component
- `duration` - Auto-dismiss duration (milliseconds)

#### Toaster
- `closeButton` - Show close button on toasts
- `position` - Toast position
- `expand` - Expand toasts on hover
- `richColors` - Use semantic colors
- `theme` - Theme ('light', 'dark', 'system')

## Accessibility

- Toasts are announced by screen readers
- Action buttons are properly labeled
- Keyboard navigation support
- Focus management for actions

## Documentation

- [Official Toast Documentation](https://www.shadcn-svelte.com/docs/components/toast)
- [Bits UI Toast Documentation](https://bits-ui.com/docs/components/toast)
