# Avatar Component

## Installation

```bash
bunx shadcn-svelte@latest add avatar
```

## Usage

```svelte
<script>
  import * as Avatar from "$lib/components/ui/avatar";
</script>

<!-- Basic avatar -->
<Avatar.Root>
  <Avatar.Image src="https://github.com/shadcn.png" alt="@shadcn" />
  <Avatar.Fallback>CN</Avatar.Fallback>
</Avatar.Root>

<!-- Avatar with different sizes -->
<div class="flex items-center gap-4">
  <Avatar.Root class="h-6 w-6">
    <Avatar.Image src="https://github.com/vercel.png" alt="@vercel" />
    <Avatar.Fallback>VC</Avatar.Fallback>
  </Avatar.Root>
  
  <Avatar.Root class="h-8 w-8">
    <Avatar.Image src="https://github.com/vercel.png" alt="@vercel" />
    <Avatar.Fallback>VC</Avatar.Fallback>
  </Avatar.Root>
  
  <Avatar.Root>
    <Avatar.Image src="https://github.com/vercel.png" alt="@vercel" />
    <Avatar.Fallback>VC</Avatar.Fallback>
  </Avatar.Root>
  
  <Avatar.Root class="h-12 w-12">
    <Avatar.Image src="https://github.com/vercel.png" alt="@vercel" />
    <Avatar.Fallback>VC</Avatar.Fallback>
  </Avatar.Root>
  
  <Avatar.Root class="h-16 w-16">
    <Avatar.Image src="https://github.com/vercel.png" alt="@vercel" />
    <Avatar.Fallback>VC</Avatar.Fallback>
  </Avatar.Root>
</div>

<!-- Avatar fallback when image fails -->
<Avatar.Root>
  <Avatar.Image src="https://broken-image-url.jpg" alt="Broken" />
  <Avatar.Fallback>JD</Avatar.Fallback>
</Avatar.Root>

<!-- Avatar with user data -->
<script>
  const user = {
    name: "John Doe",
    email: "john@example.com",
    avatar: "https://github.com/johndoe.png"
  };
  
  function getInitials(name) {
    return name
      .split(' ')
      .map(n => n[0])
      .join('')
      .toUpperCase();
  }
</script>

<div class="flex items-center gap-3">
  <Avatar.Root>
    <Avatar.Image src={user.avatar} alt={user.name} />
    <Avatar.Fallback>{getInitials(user.name)}</Avatar.Fallback>
  </Avatar.Root>
  <div>
    <p class="text-sm font-medium">{user.name}</p>
    <p class="text-xs text-muted-foreground">{user.email}</p>
  </div>
</div>

<!-- Avatar group -->
<div class="flex -space-x-2">
  <Avatar.Root class="border-2 border-background">
    <Avatar.Image src="https://github.com/shadcn.png" alt="User 1" />
    <Avatar.Fallback>U1</Avatar.Fallback>
  </Avatar.Root>
  <Avatar.Root class="border-2 border-background">
    <Avatar.Image src="https://github.com/vercel.png" alt="User 2" />
    <Avatar.Fallback>U2</Avatar.Fallback>
  </Avatar.Root>
  <Avatar.Root class="border-2 border-background">
    <Avatar.Image src="https://github.com/nextjs.png" alt="User 3" />
    <Avatar.Fallback>U3</Avatar.Fallback>
  </Avatar.Root>
  <Avatar.Root class="border-2 border-background bg-muted">
    <Avatar.Fallback>+2</Avatar.Fallback>
  </Avatar.Root>
</div>

<!-- Avatar with status indicator -->
<div class="relative">
  <Avatar.Root>
    <Avatar.Image src="https://github.com/shadcn.png" alt="User" />
    <Avatar.Fallback>CN</Avatar.Fallback>
  </Avatar.Root>
  <div class="absolute bottom-0 right-0 h-3 w-3 rounded-full bg-green-500 border-2 border-background"></div>
</div>

<!-- Different status indicators -->
<div class="flex items-center gap-6">
  <!-- Online -->
  <div class="relative">
    <Avatar.Root>
      <Avatar.Image src="https://github.com/user1.png" alt="Online User" />
      <Avatar.Fallback>ON</Avatar.Fallback>
    </Avatar.Root>
    <div class="absolute bottom-0 right-0 h-3 w-3 rounded-full bg-green-500 border-2 border-background"></div>
  </div>
  
  <!-- Away -->
  <div class="relative">
    <Avatar.Root>
      <Avatar.Image src="https://github.com/user2.png" alt="Away User" />
      <Avatar.Fallback>AW</Avatar.Fallback>
    </Avatar.Root>
    <div class="absolute bottom-0 right-0 h-3 w-3 rounded-full bg-yellow-500 border-2 border-background"></div>
  </div>
  
  <!-- Busy -->
  <div class="relative">
    <Avatar.Root>
      <Avatar.Image src="https://github.com/user3.png" alt="Busy User" />
      <Avatar.Fallback>BS</Avatar.Fallback>
    </Avatar.Root>
    <div class="absolute bottom-0 right-0 h-3 w-3 rounded-full bg-red-500 border-2 border-background"></div>
  </div>
  
  <!-- Offline -->
  <div class="relative">
    <Avatar.Root>
      <Avatar.Image src="https://github.com/user4.png" alt="Offline User" />
      <Avatar.Fallback>OF</Avatar.Fallback>
    </Avatar.Root>
    <div class="absolute bottom-0 right-0 h-3 w-3 rounded-full bg-gray-400 border-2 border-background"></div>
  </div>
</div>

<!-- Avatar in different contexts -->
<!-- Comment/Message -->
<div class="flex gap-3 p-4">
  <Avatar.Root class="h-8 w-8">
    <Avatar.Image src="https://github.com/user.png" alt="User" />
    <Avatar.Fallback>U</Avatar.Fallback>
  </Avatar.Root>
  <div class="flex-1">
    <div class="flex items-center gap-2">
      <span class="font-semibold text-sm">John Doe</span>
      <span class="text-xs text-muted-foreground">2 hours ago</span>
    </div>
    <p class="text-sm mt-1">This is a comment with an avatar.</p>
  </div>
</div>

<!-- Profile card -->
<div class="p-6 border rounded-lg max-w-sm">
  <div class="flex items-center gap-4">
    <Avatar.Root class="h-16 w-16">
      <Avatar.Image src="https://github.com/profile.png" alt="Profile" />
      <Avatar.Fallback class="text-lg">JD</Avatar.Fallback>
    </Avatar.Root>
    <div>
      <h3 class="font-semibold">John Doe</h3>
      <p class="text-sm text-muted-foreground">Software Engineer</p>
      <p class="text-xs text-muted-foreground">San Francisco, CA</p>
    </div>
  </div>
</div>
```

## Components

- `Avatar.Root` - Avatar container
- `Avatar.Image` - Avatar image element
- `Avatar.Fallback` - Fallback content when image fails to load

## Props

### Avatar.Root
- `class` - Additional CSS classes

### Avatar.Image
- `src` - Image source URL
- `alt` - Alternative text for accessibility
- `class` - Additional CSS classes

### Avatar.Fallback
- `class` - Additional CSS classes

## Sizes

Common avatar sizes using Tailwind classes:

```svelte
<!-- Extra small -->
<Avatar.Root class="h-6 w-6">

<!-- Small -->
<Avatar.Root class="h-8 w-8">

<!-- Default -->
<Avatar.Root>  <!-- 40px / h-10 w-10 -->

<!-- Medium -->
<Avatar.Root class="h-12 w-12">

<!-- Large -->
<Avatar.Root class="h-16 w-16">

<!-- Extra large -->
<Avatar.Root class="h-20 w-20">
```

## Patterns

### User initials fallback
```svelte
<script>
  function getInitials(name) {
    return name
      .split(' ')
      .map(word => word[0])
      .join('')
      .toUpperCase()
      .slice(0, 2); // Limit to 2 characters
  }
</script>

<Avatar.Root>
  <Avatar.Image src={user.profileImage} alt={user.name} />
  <Avatar.Fallback>{getInitials(user.name)}</Avatar.Fallback>
</Avatar.Root>
```

### Avatar with tooltip
```svelte
<Tooltip.Root>
  <Tooltip.Trigger>
    <Avatar.Root>
      <Avatar.Image src={user.avatar} alt={user.name} />
      <Avatar.Fallback>{user.initials}</Avatar.Fallback>
    </Avatar.Root>
  </Tooltip.Trigger>
  <Tooltip.Content>
    <p>{user.name}</p>
    <p class="text-xs opacity-75">{user.email}</p>
  </Tooltip.Content>
</Tooltip.Root>
```

### Clickable avatar
```svelte
<button on:click={openProfile} class="rounded-full">
  <Avatar.Root>
    <Avatar.Image src={user.avatar} alt={user.name} />
    <Avatar.Fallback>{user.initials}</Avatar.Fallback>
  </Avatar.Root>
</button>
```

## Best Practices

- Always provide meaningful alt text for images
- Use initials or icons as fallbacks
- Consider different sizes for different contexts
- Ensure sufficient contrast for fallback text
- Use consistent sizing across your application
- Handle loading and error states gracefully

## Accessibility

- Proper alt text for screen readers
- Sufficient color contrast for fallback text
- Keyboard navigation when interactive

## Documentation

- [Official Avatar Documentation](https://www.shadcn-svelte.com/docs/components/avatar)
- [Bits UI Avatar](https://bits-ui.com/docs/components/avatar)
