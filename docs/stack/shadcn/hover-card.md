# Hover Card Component

## Installation

```bash
bunx shadcn-svelte@latest add hover-card
```

## Usage

```svelte
<script>
  import * as HoverCard from "$lib/components/ui/hover-card";
  import { Button } from "$lib/components/ui/button";
  import { Avatar, AvatarFallback, AvatarImage } from "$lib/components/ui/avatar";
  import { Calendar } from "phosphor-svelte";
</script>

<HoverCard.Root>
  <HoverCard.Trigger asChild let:builder>
    <Button builders={[builder]} variant="link">@nextjs</Button>
  </HoverCard.Trigger>
  <HoverCard.Content class="w-80">
    <div class="flex justify-between space-x-4">
      <Avatar>
        <AvatarImage src="https://github.com/vercel.png" />
        <AvatarFallback>VC</AvatarFallback>
      </Avatar>
      <div class="space-y-1">
        <h4 class="text-sm font-semibold">@nextjs</h4>
        <p class="text-sm">
          The React Framework – created and maintained by @vercel.
        </p>
        <div class="flex items-center pt-2">
          <Calendar class="mr-2 h-4 w-4 opacity-70" />
          <span class="text-xs text-muted-foreground">
            Joined December 2021
          </span>
        </div>
      </div>
    </div>
  </HoverCard.Content>
</HoverCard.Root>
```

## With Custom Positioning

```svelte
<HoverCard.Root openDelay={300} closeDelay={100}>
  <HoverCard.Trigger asChild let:builder>
    <Button builders={[builder]} variant="outline">Hover me</Button>
  </HoverCard.Trigger>
  <HoverCard.Content side="top" class="w-64">
    <div class="space-y-2">
      <h4 class="text-sm font-semibold">Pro Tip</h4>
      <p class="text-sm text-muted-foreground">
        This hover card appears on top with custom timing.
      </p>
    </div>
  </HoverCard.Content>
</HoverCard.Root>
```

## User Profile Example

```svelte
<script>
  import * as HoverCard from "$lib/components/ui/hover-card";
  import { Button } from "$lib/components/ui/button";
  import { Avatar, AvatarFallback, AvatarImage } from "$lib/components/ui/avatar";
  import { Badge } from "$lib/components/ui/badge";
  import { MapPin, Link as LinkIcon, Calendar } from "phosphor-svelte";
  
  const user = {
    name: "Jane Doe",
    username: "janedoe",
    avatar: "https://github.com/janedoe.png",
    bio: "Software engineer and open source contributor",
    location: "San Francisco, CA",
    website: "https://janedoe.dev",
    joinDate: "Joined March 2020",
    followers: 1234,
    following: 567,
  };
</script>

<HoverCard.Root>
  <HoverCard.Trigger asChild let:builder>
    <Button builders={[builder]} variant="link">@{user.username}</Button>
  </HoverCard.Trigger>
  <HoverCard.Content class="w-80">
    <div class="space-y-3">
      <div class="flex items-start space-x-3">
        <Avatar>
          <AvatarImage src={user.avatar} alt={user.name} />
          <AvatarFallback>{user.name.split(' ').map(n => n[0]).join('')}</AvatarFallback>
        </Avatar>
        <div class="space-y-1 flex-1">
          <h4 class="text-sm font-semibold">{user.name}</h4>
          <p class="text-sm text-muted-foreground">@{user.username}</p>
        </div>
      </div>
      
      <p class="text-sm">{user.bio}</p>
      
      <div class="flex flex-wrap gap-2 text-sm text-muted-foreground">
        <div class="flex items-center gap-1">
          <MapPin class="h-3 w-3" />
          {user.location}
        </div>
        <div class="flex items-center gap-1">
          <LinkIcon class="h-3 w-3" />
          <a href={user.website} class="hover:underline">janedoe.dev</a>
        </div>
      </div>
      
      <div class="flex items-center gap-4 text-sm">
        <span><strong>{user.followers}</strong> followers</span>
        <span><strong>{user.following}</strong> following</span>
      </div>
      
      <div class="flex items-center gap-1 text-xs text-muted-foreground">
        <Calendar class="h-3 w-3" />
        {user.joinDate}
      </div>
    </div>
  </HoverCard.Content>
</HoverCard.Root>
```

## Props

### Root
- `openDelay` - Delay before showing (milliseconds)
- `closeDelay` - Delay before hiding (milliseconds)
- `open` - Controlled open state
- `onOpenChange` - Open state change handler

### Trigger
- `asChild` - Render as child component

### Content
- `side` - Preferred side ('top', 'right', 'bottom', 'left')
- `sideOffset` - Offset from the trigger
- `align` - Alignment relative to trigger
- `alignOffset` - Alignment offset
- `avoidCollisions` - Avoid viewport collisions
- `collisionBoundary` - Collision boundary element
- `collisionPadding` - Collision padding
- `sticky` - Sticky positioning behavior
- `class` - Additional CSS classes

## Documentation

- [Official Hover Card Documentation](https://www.shadcn-svelte.com/docs/components/hover-card)
- [Bits UI Hover Card Documentation](https://bits-ui.com/docs/components/hover-card)
