# Aspect Ratio Component

## Installation

```bash
bunx shadcn-svelte@latest add aspect-ratio
```

## Usage

```svelte
<script>
  import { AspectRatio } from "$lib/components/ui/aspect-ratio";
</script>

<!-- 16:9 aspect ratio (default) -->
<div class="w-[450px]">
  <AspectRatio ratio={16 / 9}>
    <img
      src="/landscape.jpg"
      alt="Landscape"
      class="rounded-md object-cover w-full h-full"
    />
  </AspectRatio>
</div>

<!-- Square aspect ratio -->
<div class="w-[300px]">
  <AspectRatio ratio={1}>
    <img
      src="/avatar.jpg"
      alt="Avatar"
      class="rounded-full object-cover w-full h-full"
    />
  </AspectRatio>
</div>

<!-- 4:3 aspect ratio -->
<div class="w-[400px]">
  <AspectRatio ratio={4 / 3}>
    <img
      src="/photo.jpg"
      alt="Photo"
      class="object-cover w-full h-full"
    />
  </AspectRatio>
</div>

<!-- Video embed -->
<div class="w-full max-w-3xl">
  <AspectRatio ratio={16 / 9}>
    <iframe
      src="https://www.youtube.com/embed/dQw4w9WgXcQ"
      title="YouTube video"
      class="w-full h-full"
      frameborder="0"
      allowfullscreen
    ></iframe>
  </AspectRatio>
</div>

<!-- Placeholder content -->
<div class="w-[450px]">
  <AspectRatio ratio={16 / 9} class="bg-muted">
    <div class="flex h-full items-center justify-center">
      <p class="text-muted-foreground">16:9</p>
    </div>
  </AspectRatio>
</div>

<!-- Gallery with consistent aspect ratios -->
<div class="grid grid-cols-3 gap-4">
  {#each images as image}
    <AspectRatio ratio={4 / 3}>
      <img
        src={image.src}
        alt={image.alt}
        class="rounded-md object-cover w-full h-full"
      />
    </AspectRatio>
  {/each}
</div>
```

## Props

- `ratio` - Aspect ratio (width / height)
  - Default: 1 (square)
  - Common ratios:
    - 16/9 - Widescreen
    - 4/3 - Standard
    - 1 - Square
    - 21/9 - Ultrawide
    - 9/16 - Portrait
- `class` - Additional CSS classes

## Common Ratios

```svelte
<!-- Widescreen (16:9) -->
<AspectRatio ratio={16 / 9} />

<!-- Standard (4:3) -->
<AspectRatio ratio={4 / 3} />

<!-- Square (1:1) -->
<AspectRatio ratio={1} />

<!-- Portrait (9:16) -->
<AspectRatio ratio={9 / 16} />

<!-- Ultrawide (21:9) -->
<AspectRatio ratio={21 / 9} />

<!-- Golden ratio -->
<AspectRatio ratio={1.618} />
```

## Use Cases

### Product Images
```svelte
<div class="grid grid-cols-2 md:grid-cols-4 gap-4">
  {#each products as product}
    <Card.Root>
      <AspectRatio ratio={1}>
        <img
          src={product.image}
          alt={product.name}
          class="object-cover w-full h-full rounded-t-lg"
        />
      </AspectRatio>
      <Card.Content class="p-4">
        <h3 class="font-semibold">{product.name}</h3>
        <p class="text-sm text-muted-foreground">${product.price}</p>
      </Card.Content>
    </Card.Root>
  {/each}
</div>
```

### Media Player
```svelte
<div class="max-w-4xl mx-auto">
  <AspectRatio ratio={16 / 9} class="bg-black">
    <video
      controls
      class="w-full h-full"
      poster="/video-poster.jpg"
    >
      <source src="/video.mp4" type="video/mp4" />
      Your browser does not support the video tag.
    </video>
  </AspectRatio>
  <div class="mt-4">
    <h2 class="text-xl font-bold">Video Title</h2>
    <p class="text-muted-foreground">Video description</p>
  </div>
</div>
```

## Documentation

- [Official Aspect Ratio Documentation](https://www.shadcn-svelte.com/docs/components/aspect-ratio)
- [Bits UI Aspect Ratio](https://bits-ui.com/docs/components/aspect-ratio)
