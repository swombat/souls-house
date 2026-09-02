# Skeleton Component

## Installation

```bash
bunx shadcn-svelte@latest add skeleton
```

## Usage

```svelte
<script>
  import { Skeleton } from "$lib/components/ui/skeleton";
</script>

<div class="flex items-center space-x-4">
  <Skeleton class="h-12 w-12 rounded-full" />
  <div class="space-y-2">
    <Skeleton class="h-4 w-[250px]" />
    <Skeleton class="h-4 w-[200px]" />
  </div>
</div>
```

## Card Skeleton

```svelte
<div class="flex flex-col space-y-3">
  <Skeleton class="h-[125px] w-[250px] rounded-xl" />
  <div class="space-y-2">
    <Skeleton class="h-4 w-[250px]" />
    <Skeleton class="h-4 w-[200px]" />
  </div>
</div>
```

## List Skeleton

```svelte
<div class="space-y-4">
  {#each Array(3) as _}
    <div class="flex items-center space-x-4">
      <Skeleton class="h-10 w-10 rounded-full" />
      <div class="space-y-2 flex-1">
        <Skeleton class="h-3 w-full" />
        <Skeleton class="h-3 w-4/5" />
      </div>
    </div>
  {/each}
</div>
```

## Table Skeleton

```svelte
<div class="space-y-2">
  <!-- Header -->
  <div class="flex space-x-4">
    <Skeleton class="h-6 w-[100px]" />
    <Skeleton class="h-6 w-[150px]" />
    <Skeleton class="h-6 w-[120px]" />
    <Skeleton class="h-6 w-[80px]" />
  </div>
  
  <!-- Rows -->
  {#each Array(5) as _}
    <div class="flex space-x-4">
      <Skeleton class="h-4 w-[100px]" />
      <Skeleton class="h-4 w-[150px]" />
      <Skeleton class="h-4 w-[120px]" />
      <Skeleton class="h-4 w-[80px]" />
    </div>
  {/each}
</div>
```

## Article Skeleton

```svelte
<div class="space-y-4">
  <!-- Title -->
  <Skeleton class="h-8 w-3/4" />
  
  <!-- Meta info -->
  <div class="flex items-center space-x-2">
    <Skeleton class="h-4 w-4 rounded-full" />
    <Skeleton class="h-4 w-[100px]" />
    <Skeleton class="h-4 w-[80px]" />
  </div>
  
  <!-- Featured image -->
  <Skeleton class="h-[200px] w-full rounded-lg" />
  
  <!-- Content paragraphs -->
  <div class="space-y-2">
    <Skeleton class="h-4 w-full" />
    <Skeleton class="h-4 w-full" />
    <Skeleton class="h-4 w-3/4" />
  </div>
  
  <div class="space-y-2">
    <Skeleton class="h-4 w-full" />
    <Skeleton class="h-4 w-5/6" />
  </div>
</div>
```

## Profile Card Skeleton

```svelte
<div class="border rounded-lg p-6 space-y-4">
  <!-- Profile header -->
  <div class="flex items-center space-x-4">
    <Skeleton class="h-16 w-16 rounded-full" />
    <div class="space-y-2 flex-1">
      <Skeleton class="h-5 w-[200px]" />
      <Skeleton class="h-4 w-[150px]" />
    </div>
  </div>
  
  <!-- Bio -->
  <div class="space-y-2">
    <Skeleton class="h-4 w-full" />
    <Skeleton class="h-4 w-4/5" />
    <Skeleton class="h-4 w-3/5" />
  </div>
  
  <!-- Stats -->
  <div class="flex justify-between pt-4 border-t">
    <div class="text-center space-y-2">
      <Skeleton class="h-6 w-12 mx-auto" />
      <Skeleton class="h-4 w-16" />
    </div>
    <div class="text-center space-y-2">
      <Skeleton class="h-6 w-12 mx-auto" />
      <Skeleton class="h-4 w-20" />
    </div>
    <div class="text-center space-y-2">
      <Skeleton class="h-6 w-12 mx-auto" />
      <Skeleton class="h-4 w-18" />
    </div>
  </div>
</div>
```

## Loading State Integration

```svelte
<script>
  import { Skeleton } from "$lib/components/ui/skeleton";
  import { onMount } from "svelte";
  
  let posts = [];
  let loading = true;
  
  onMount(async () => {
    try {
      const response = await fetch('/api/posts');
      posts = await response.json();
    } finally {
      loading = false;
    }
  });
</script>

<div class="space-y-6">
  {#if loading}
    {#each Array(3) as _}
      <div class="border rounded-lg p-6 space-y-4">
        <div class="flex items-center space-x-4">
          <Skeleton class="h-10 w-10 rounded-full" />
          <div class="space-y-2 flex-1">
            <Skeleton class="h-4 w-[200px]" />
            <Skeleton class="h-3 w-[100px]" />
          </div>
        </div>
        <Skeleton class="h-[200px] w-full rounded-lg" />
        <div class="space-y-2">
          <Skeleton class="h-4 w-full" />
          <Skeleton class="h-4 w-4/5" />
        </div>
      </div>
    {/each}
  {:else}
    {#each posts as post}
      <article class="border rounded-lg p-6">
        <h2 class="text-xl font-semibold">{post.title}</h2>
        <p class="text-muted-foreground">{post.excerpt}</p>
      </article>
    {/each}
  {/if}
</div>
```

## Props

- `class` - Additional CSS classes for styling

## Best Practices

1. **Match Content Structure**: Design skeletons that closely match the final content layout
2. **Consistent Sizing**: Use consistent spacing and sizing with your actual components
3. **Loading Duration**: Don't show skeletons for very quick loading states (< 300ms)
4. **Progressive Loading**: Show more detailed skeletons for longer loading operations
5. **Accessibility**: Skeletons include appropriate ARIA labels for screen readers

## Documentation

- [Official Skeleton Documentation](https://www.shadcn-svelte.com/docs/components/skeleton)
