# Carousel Component

## Installation

```bash
bunx shadcn-svelte@latest add carousel
```

## Usage

```svelte
<script>
  import * as Carousel from "$lib/components/ui/carousel";
</script>

<Carousel.Root class="w-full max-w-xs">
  <Carousel.Content>
    <Carousel.Item>
      <div class="p-1">
        <div class="flex aspect-square items-center justify-center p-6">
          <span class="text-4xl font-semibold">1</span>
        </div>
      </div>
    </Carousel.Item>
    <Carousel.Item>
      <div class="p-1">
        <div class="flex aspect-square items-center justify-center p-6">
          <span class="text-4xl font-semibold">2</span>
        </div>
      </div>
    </Carousel.Item>
    <Carousel.Item>
      <div class="p-1">
        <div class="flex aspect-square items-center justify-center p-6">
          <span class="text-4xl font-semibold">3</span>
        </div>
      </div>
    </Carousel.Item>
  </Carousel.Content>
  <Carousel.Previous />
  <Carousel.Next />
</Carousel.Root>
```

## With Multiple Items

```svelte
<Carousel.Root class="w-full max-w-sm">
  <Carousel.Content class="-ml-1">
    {#each Array(5) as _, i}
      <Carousel.Item class="pl-1 md:basis-1/2 lg:basis-1/3">
        <div class="p-1">
          <div class="flex aspect-square items-center justify-center p-6">
            <span class="text-2xl font-semibold">{i + 1}</span>
          </div>
        </div>
      </Carousel.Item>
    {/each}
  </Carousel.Content>
  <Carousel.Previous />
  <Carousel.Next />
</Carousel.Root>
```

## Vertical Carousel

```svelte
<Carousel.Root orientation="vertical" class="w-full max-w-xs">
  <Carousel.Content class="-mt-1 h-[200px]">
    {#each Array(3) as _, i}
      <Carousel.Item class="pt-1 basis-1/3">
        <div class="flex items-center justify-center p-6">
          <span class="text-2xl font-semibold">{i + 1}</span>
        </div>
      </Carousel.Item>
    {/each}
  </Carousel.Content>
  <Carousel.Previous />
  <Carousel.Next />
</Carousel.Root>
```

## API Reference

```svelte
<script>
  import * as Carousel from "$lib/components/ui/carousel";
  
  let api;
  
  function scrollPrev() {
    api?.scrollPrev();
  }
  
  function scrollNext() {
    api?.scrollNext();
  }
</script>

<Carousel.Root bind:api>
  <!-- Carousel content -->
</Carousel.Root>

<button on:click={scrollPrev}>Previous</button>
<button on:click={scrollNext}>Next</button>
```

## Props

### Root
- `orientation` - 'horizontal' or 'vertical'
- `opts` - Embla carousel options
- `plugins` - Embla carousel plugins
- `api` - Carousel API instance
- `class` - Additional CSS classes

### Content
- `class` - Additional CSS classes

### Item
- `class` - Additional CSS classes

### Previous/Next
- `class` - Additional CSS classes

## Documentation

- [Official Carousel Documentation](https://www.shadcn-svelte.com/docs/components/carousel)
- [Embla Carousel Documentation](https://www.embla-carousel.com/)
