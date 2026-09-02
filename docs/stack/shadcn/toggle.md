# Toggle Component

## Installation

```bash
bunx shadcn-svelte@latest add toggle
```

## Usage

```svelte
<script>
  import { Toggle } from "$lib/components/ui/toggle";
  import { TextB } from "phosphor-svelte";
  
  let pressed = false;
</script>

<Toggle bind:pressed>
  <Bold class="h-4 w-4" />
</Toggle>
```

## With Text

```svelte
<script>
  import { Toggle } from "$lib/components/ui/toggle";
  import { TextItalic } from "phosphor-svelte";
  
  let pressed = false;
</script>

<Toggle bind:pressed>
  <TextItalic class="mr-2 h-4 w-4" />
  Italic
</Toggle>
```

## Variants

```svelte
<script>
  import { Toggle } from "$lib/components/ui/toggle";
  import { TextB } from "phosphor-svelte";
  
  let pressed1 = false;
  let pressed2 = false;
  let pressed3 = false;
</script>

<div class="flex items-center space-x-2">
  <Toggle variant="default" bind:pressed={pressed1}>
    <Bold class="h-4 w-4" />
  </Toggle>
  
  <Toggle variant="outline" bind:pressed={pressed2}>
    <Bold class="h-4 w-4" />
  </Toggle>
  
  <Toggle variant="subtle" bind:pressed={pressed3}>
    <Bold class="h-4 w-4" />
  </Toggle>
</div>
```

## Sizes

```svelte
<script>
  import { Toggle } from "$lib/components/ui/toggle";
  import { TextB } from "phosphor-svelte";
  
  let pressed1 = false;
  let pressed2 = false;
  let pressed3 = false;
</script>

<div class="flex items-center space-x-2">
  <Toggle size="sm" bind:pressed={pressed1}>
    <TextB class="h-3 w-3" />
  </Toggle>
  
  <Toggle size="default" bind:pressed={pressed2}>
    <Bold class="h-4 w-4" />
  </Toggle>
  
  <Toggle size="lg" bind:pressed={pressed3}>
    <TextB class="h-5 w-5" />
  </Toggle>
</div>
```

## Disabled State

```svelte
<script>
  import { Toggle } from "$lib/components/ui/toggle";
  import { TextUnderline } from "phosphor-svelte";
</script>

<Toggle disabled>
  <TextUnderline class="h-4 w-4" />
</Toggle>
```

## Text Editor Example

```svelte
<script>
  import { Toggle } from "$lib/components/ui/toggle";
  import { TextB, TextItalic, TextUnderline, TextStrikethrough } from "phosphor-svelte";
  
  let bold = false;
  let italic = false;
  let underline = false;
  let strikethrough = false;
</script>

<div class="flex items-center space-x-1 border rounded-lg p-1">
  <Toggle bind:pressed={bold} aria-label="Toggle bold">
    <TextB class="h-4 w-4" />
  </Toggle>
  
  <Toggle bind:pressed={italic} aria-label="Toggle italic">
    <TextItalic class="h-4 w-4" />
  </Toggle>
  
  <Toggle bind:pressed={underline} aria-label="Toggle underline">
    <TextUnderline class="h-4 w-4" />
  </Toggle>
  
  <Toggle bind:pressed={strikethrough} aria-label="Toggle strikethrough">
    <TextStrikethrough class="h-4 w-4" />
  </Toggle>
</div>

<!-- Preview area -->
<div class="mt-4 p-4 border rounded">
  <p 
    class:font-bold={bold}
    class:italic
    class:underline
    class:line-through={strikethrough}
  >
    Sample text with formatting applied
  </p>
</div>
```

## View Mode Toggle

```svelte
<script>
  import { Toggle } from "$lib/components/ui/toggle";
  import { GridFour, ListBullets } from "phosphor-svelte";
  
  let gridView = true;
</script>

<div class="flex items-center space-x-2">
  <Toggle 
    pressed={gridView}
    on:click={() => gridView = true}
    aria-label="Grid view"
  >
    <GridFour class="h-4 w-4" />
  </Toggle>
  
  <Toggle 
    pressed={!gridView}
    on:click={() => gridView = false}
    aria-label="List view"
  >
    <ListBullets class="h-4 w-4" />
  </Toggle>
</div>

<!-- Content display -->
<div class="mt-4">
  {#if gridView}
    <div class="grid grid-cols-3 gap-4">
      {#each Array(6) as _, i}
        <div class="border rounded p-4 text-center">Item {i + 1}</div>
      {/each}
    </div>
  {:else}
    <div class="space-y-2">
      {#each Array(6) as _, i}
        <div class="border rounded p-4">Item {i + 1}</div>
      {/each}
    </div>
  {/if}
</div>
```

## Controlled Toggle

```svelte
<script>
  import { Toggle } from "$lib/components/ui/toggle";
  import { Button } from "$lib/components/ui/button";
  import { Heart } from "phosphor-svelte";
  
  let liked = false;
  
  function toggleLike() {
    liked = !liked;
  }
</script>

<div class="flex items-center space-x-2">
  <Toggle bind:pressed={liked} aria-label="Like post">
    <Heart class="h-4 w-4" class:text-red-500={liked} />
  </Toggle>
  
  <Button variant="outline" size="sm" on:click={toggleLike}>
    {liked ? 'Unlike' : 'Like'}
  </Button>
  
  <span class="text-sm text-muted-foreground">
    {liked ? 'You liked this' : 'Click to like'}
  </span>
</div>
```

## Props

- `pressed` - Whether the toggle is pressed
- `variant` - Toggle variant ('default', 'outline', 'subtle')
- `size` - Toggle size ('sm', 'default', 'lg')
- `disabled` - Disable the toggle
- `class` - Additional CSS classes

## Events

- `on:click` - Click handler
- `on:pressedchange` - Pressed state change handler

## Accessibility

- Uses `aria-pressed` attribute
- Supports keyboard navigation
- Can be labeled with `aria-label`
- Focus management

## Documentation

- [Official Toggle Documentation](https://www.shadcn-svelte.com/docs/components/toggle)
- [Bits UI Toggle Documentation](https://bits-ui.com/docs/components/toggle)
