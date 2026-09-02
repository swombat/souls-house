# Toggle Group Component

## Installation

```bash
bunx shadcn-svelte@latest add toggle-group
```

## Usage

```svelte
<script>
  import * as ToggleGroup from "$lib/components/ui/toggle-group";
  import { TextB, TextItalic, TextUnderline } from "phosphor-svelte";
  
  let value = ["bold"];
</script>

<ToggleGroup.Root type="multiple" bind:value>
  <ToggleGroup.Item value="bold" aria-label="Bold">
    <TextB class="h-4 w-4" />
  </ToggleGroup.Item>
  <ToggleGroup.Item value="italic" aria-label="Italic">
    <TextItalic class="h-4 w-4" />
  </ToggleGroup.Item>
  <ToggleGroup.Item value="underline" aria-label="Underline">
    <TextUnderline class="h-4 w-4" />
  </ToggleGroup.Item>
</ToggleGroup.Root>
```

## Single Selection

```svelte
<script>
  import * as ToggleGroup from "$lib/components/ui/toggle-group";
  import { TextAlignLeft, TextAlignCenter, TextAlignRight, TextAlignJustify } from "phosphor-svelte";
  
  let value = "left";
</script>

<ToggleGroup.Root type="single" bind:value>
  <ToggleGroup.Item value="left" aria-label="Align left">
    <TextAlignLeft class="h-4 w-4" />
  </ToggleGroup.Item>
  <ToggleGroup.Item value="center" aria-label="Align center">
    <TextAlignCenter class="h-4 w-4" />
  </ToggleGroup.Item>
  <ToggleGroup.Item value="right" aria-label="Align right">
    <TextAlignRight class="h-4 w-4" />
  </ToggleGroup.Item>
  <ToggleGroup.Item value="justify" aria-label="Align justify">
    <TextAlignJustify class="h-4 w-4" />
  </ToggleGroup.Item>
</ToggleGroup.Root>
```

## With Text Labels

```svelte
<script>
  import * as ToggleGroup from "$lib/components/ui/toggle-group";
  
  let value = "left";
</script>

<ToggleGroup.Root type="single" bind:value>
  <ToggleGroup.Item value="left">Left</ToggleGroup.Item>
  <ToggleGroup.Item value="center">Center</ToggleGroup.Item>
  <ToggleGroup.Item value="right">Right</ToggleGroup.Item>
</ToggleGroup.Root>
```

## Variants

```svelte
<script>
  import * as ToggleGroup from "$lib/components/ui/toggle-group";
  import { TextB, TextItalic, TextUnderline } from "phosphor-svelte";
  
  let value1 = [];
  let value2 = [];
  let value3 = [];
</script>

<!-- Default variant -->
<ToggleGroup.Root type="multiple" variant="default" bind:value={value1}>
  <ToggleGroup.Item value="bold"><TextB class="h-4 w-4" /></ToggleGroup.Item>
  <ToggleGroup.Item value="italic"><TextItalic class="h-4 w-4" /></ToggleGroup.Item>
  <ToggleGroup.Item value="underline"><TextUnderline class="h-4 w-4" /></ToggleGroup.Item>
</ToggleGroup.Root>

<!-- Outline variant -->
<ToggleGroup.Root type="multiple" variant="outline" bind:value={value2}>
  <ToggleGroup.Item value="bold"><TextB class="h-4 w-4" /></ToggleGroup.Item>
  <ToggleGroup.Item value="italic"><TextItalic class="h-4 w-4" /></ToggleGroup.Item>
  <ToggleGroup.Item value="underline"><TextUnderline class="h-4 w-4" /></ToggleGroup.Item>
</ToggleGroup.Root>

<!-- Subtle variant -->
<ToggleGroup.Root type="multiple" variant="subtle" bind:value={value3}>
  <ToggleGroup.Item value="bold"><TextB class="h-4 w-4" /></ToggleGroup.Item>
  <ToggleGroup.Item value="italic"><TextItalic class="h-4 w-4" /></ToggleGroup.Item>
  <ToggleGroup.Item value="underline"><TextUnderline class="h-4 w-4" /></ToggleGroup.Item>
</ToggleGroup.Root>
```

## Sizes

```svelte
<script>
  import * as ToggleGroup from "$lib/components/ui/toggle-group";
  import { TextB, TextItalic, TextUnderline } from "phosphor-svelte";
</script>

<!-- Small size -->
<ToggleGroup.Root type="multiple" size="sm">
  <ToggleGroup.Item value="bold"><TextB class="h-3 w-3" /></ToggleGroup.Item>
  <ToggleGroup.Item value="italic"><TextItalic class="h-3 w-3" /></ToggleGroup.Item>
</ToggleGroup.Root>

<!-- Default size -->
<ToggleGroup.Root type="multiple" size="default">
  <ToggleGroup.Item value="bold"><TextB class="h-4 w-4" /></ToggleGroup.Item>
  <ToggleGroup.Item value="italic"><TextItalic class="h-4 w-4" /></ToggleGroup.Item>
</ToggleGroup.Root>

<!-- Large size -->
<ToggleGroup.Root type="multiple" size="lg">
  <ToggleGroup.Item value="bold"><TextB class="h-5 w-5" /></ToggleGroup.Item>
  <ToggleGroup.Item value="italic"><TextItalic class="h-5 w-5" /></ToggleGroup.Item>
</ToggleGroup.Root>
```

## Disabled Items

```svelte
<script>
  import * as ToggleGroup from "$lib/components/ui/toggle-group";
  import { TextB, TextItalic, TextUnderline } from "phosphor-svelte";
  
  let value = [];
</script>

<ToggleGroup.Root type="multiple" bind:value>
  <ToggleGroup.Item value="bold">
    <TextB class="h-4 w-4" />
  </ToggleGroup.Item>
  <ToggleGroup.Item value="italic" disabled>
    <TextItalic class="h-4 w-4" />
  </ToggleGroup.Item>
  <ToggleGroup.Item value="underline">
    <TextUnderline class="h-4 w-4" />
  </ToggleGroup.Item>
</ToggleGroup.Root>
```

## Text Editor Toolbar

```svelte
<script>
  import * as ToggleGroup from "$lib/components/ui/toggle-group";
  import { Separator } from "$lib/components/ui/separator";
  import { 
    TextB, TextItalic, TextUnderline, TextStrikethrough,
    TextAlignLeft, TextAlignCenter, TextAlignRight, TextAlignJustify,
    ListBullets, ListNumbers
  } from "phosphor-svelte";
  
  let formatting = [];
  let alignment = "left";
  let listType = "";
</script>

<div class="flex items-center space-x-2 p-2 border rounded-lg">
  <!-- Text formatting -->
  <ToggleGroup.Root type="multiple" bind:value={formatting}>
    <ToggleGroup.Item value="bold" aria-label="Bold">
      <TextB class="h-4 w-4" />
    </ToggleGroup.Item>
    <ToggleGroup.Item value="italic" aria-label="Italic">
      <TextItalic class="h-4 w-4" />
    </ToggleGroup.Item>
    <ToggleGroup.Item value="underline" aria-label="Underline">
      <TextUnderline class="h-4 w-4" />
    </ToggleGroup.Item>
    <ToggleGroup.Item value="strikethrough" aria-label="Strikethrough">
      <TextStrikethrough class="h-4 w-4" />
    </ToggleGroup.Item>
  </ToggleGroup.Root>
  
  <Separator orientation="vertical" class="h-6" />
  
  <!-- Text alignment -->
  <ToggleGroup.Root type="single" bind:value={alignment}>
    <ToggleGroup.Item value="left" aria-label="Align left">
      <TextAlignLeft class="h-4 w-4" />
    </ToggleGroup.Item>
    <ToggleGroup.Item value="center" aria-label="Align center">
      <TextAlignCenter class="h-4 w-4" />
    </ToggleGroup.Item>
    <ToggleGroup.Item value="right" aria-label="Align right">
      <TextAlignRight class="h-4 w-4" />
    </ToggleGroup.Item>
    <ToggleGroup.Item value="justify" aria-label="Align justify">
      <TextAlignJustify class="h-4 w-4" />
    </ToggleGroup.Item>
  </ToggleGroup.Root>
  
  <Separator orientation="vertical" class="h-6" />
  
  <!-- Lists -->
  <ToggleGroup.Root type="single" bind:value={listType}>
    <ToggleGroup.Item value="unordered" aria-label="Bullet list">
      <ListBullets class="h-4 w-4" />
    </ToggleGroup.Item>
    <ToggleGroup.Item value="ordered" aria-label="Numbered list">
      <ListNumbers class="h-4 w-4" />
    </ToggleGroup.Item>
  </ToggleGroup.Root>
</div>

<!-- Preview -->
<div class="mt-4 p-4 border rounded">
  <p 
    class:font-bold={formatting.includes('bold')}
    class:italic={formatting.includes('italic')}
    class:underline={formatting.includes('underline')}
    class:line-through={formatting.includes('strikethrough')}
    class:text-left={alignment === 'left'}
    class:text-center={alignment === 'center'}
    class:text-right={alignment === 'right'}
    class:text-justify={alignment === 'justify'}
  >
    This is a sample text that shows the applied formatting and alignment.
  </p>
</div>
```

## View Options

```svelte
<script>
  import * as ToggleGroup from "$lib/components/ui/toggle-group";
  import { GridFour, ListBullets, Calendar } from "phosphor-svelte";
  
  let viewMode = "grid";
</script>

<div class="space-y-4">
  <ToggleGroup.Root type="single" bind:value={viewMode}>
    <ToggleGroup.Item value="grid" aria-label="Grid view">
      <GridFour class="h-4 w-4" />
      <span class="ml-2">Grid</span>
    </ToggleGroup.Item>
    <ToggleGroup.Item value="list" aria-label="List view">
      <ListBullets class="h-4 w-4" />
      <span class="ml-2">List</span>
    </ToggleGroup.Item>
    <ToggleGroup.Item value="calendar" aria-label="Calendar view">
      <Calendar class="h-4 w-4" />
      <span class="ml-2">Calendar</span>
    </ToggleGroup.Item>
  </ToggleGroup.Root>
  
  <div class="text-sm text-muted-foreground">
    Current view: {viewMode}
  </div>
</div>
```

## Props

### Root
- `type` - Selection type ('single' or 'multiple')
- `value` - Selected value(s)
- `variant` - Visual variant ('default', 'outline', 'subtle')
- `size` - Size ('sm', 'default', 'lg')
- `disabled` - Disable all items
- `orientation` - Layout orientation ('horizontal', 'vertical')
- `class` - Additional CSS classes

### Item
- `value` - Item value
- `disabled` - Disable this item
- `class` - Additional CSS classes

## Events

- `on:valuechange` - Value change handler

## Accessibility

- Uses `role="group"` with proper ARIA attributes
- Items use `aria-pressed` state
- Supports keyboard navigation
- Proper focus management

## Documentation

- [Official Toggle Group Documentation](https://www.shadcn-svelte.com/docs/components/toggle-group)
- [Bits UI Toggle Group Documentation](https://bits-ui.com/docs/components/toggle-group)
