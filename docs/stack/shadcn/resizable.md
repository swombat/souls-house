# Resizable Component

## Installation

```bash
bunx shadcn-svelte@latest add resizable
```

## Usage

```svelte
<script>
  import * as Resizable from "$lib/components/ui/resizable";
</script>

<Resizable.PaneGroup direction="horizontal" class="max-w-md rounded-lg border">
  <Resizable.Pane defaultSize={50}>
    <div class="flex h-[200px] items-center justify-center p-6">
      <span class="font-semibold">One</span>
    </div>
  </Resizable.Pane>
  <Resizable.Handle />
  <Resizable.Pane defaultSize={50}>
    <div class="flex h-[200px] items-center justify-center p-6">
      <span class="font-semibold">Two</span>
    </div>
  </Resizable.Pane>
</Resizable.PaneGroup>
```

## Vertical Layout

```svelte
<Resizable.PaneGroup direction="vertical" class="min-h-[200px] max-w-md rounded-lg border">
  <Resizable.Pane defaultSize={25}>
    <div class="flex h-full items-center justify-center p-6">
      <span class="font-semibold">Header</span>
    </div>
  </Resizable.Pane>
  <Resizable.Handle />
  <Resizable.Pane defaultSize={75}>
    <div class="flex h-full items-center justify-center p-6">
      <span class="font-semibold">Content</span>
    </div>
  </Resizable.Pane>
</Resizable.PaneGroup>
```

## Three Panes

```svelte
<Resizable.PaneGroup direction="horizontal" class="min-h-[200px] max-w-md rounded-lg border">
  <Resizable.Pane defaultSize={33}>
    <div class="flex h-full items-center justify-center p-6">
      <span class="font-semibold">Sidebar</span>
    </div>
  </Resizable.Pane>
  <Resizable.Handle withHandle />
  <Resizable.Pane defaultSize={34}>
    <div class="flex h-full items-center justify-center p-6">
      <span class="font-semibold">Content</span>
    </div>
  </Resizable.Pane>
  <Resizable.Handle withHandle />
  <Resizable.Pane defaultSize={33}>
    <div class="flex h-full items-center justify-center p-6">
      <span class="font-semibold">Sidebar</span>
    </div>
  </Resizable.Pane>
</Resizable.PaneGroup>
```

## With Handle

```svelte
<Resizable.PaneGroup direction="horizontal" class="min-h-[200px] max-w-md rounded-lg border">
  <Resizable.Pane defaultSize={25}>
    <div class="flex h-full items-center justify-center p-6">
      <span class="font-semibold">Left</span>
    </div>
  </Resizable.Pane>
  <Resizable.Handle withHandle />
  <Resizable.Pane defaultSize={75}>
    <div class="flex h-full items-center justify-center p-6">
      <span class="font-semibold">Right</span>
    </div>
  </Resizable.Pane>
</Resizable.PaneGroup>
```

## Nested Resizable

```svelte
<Resizable.PaneGroup direction="horizontal" class="min-h-[200px] max-w-md rounded-lg border">
  <Resizable.Pane defaultSize={25}>
    <div class="flex h-full items-center justify-center p-6">
      <span class="font-semibold">Left</span>
    </div>
  </Resizable.Pane>
  <Resizable.Handle withHandle />
  <Resizable.Pane defaultSize={75}>
    <Resizable.PaneGroup direction="vertical">
      <Resizable.Pane defaultSize={25}>
        <div class="flex h-full items-center justify-center p-6">
          <span class="font-semibold">Top</span>
        </div>
      </Resizable.Pane>
      <Resizable.Handle />
      <Resizable.Pane defaultSize={75}>
        <div class="flex h-full items-center justify-center p-6">
          <span class="font-semibold">Bottom</span>
        </div>
      </Resizable.Pane>
    </Resizable.PaneGroup>
  </Resizable.Pane>
</Resizable.PaneGroup>
```

## Code Editor Layout Example

```svelte
<script>
  import * as Resizable from "$lib/components/ui/resizable";
</script>

<div class="h-screen">
  <Resizable.PaneGroup direction="horizontal">
    <!-- File Explorer -->
    <Resizable.Pane defaultSize={20} minSize={15} maxSize={30}>
      <div class="flex h-full flex-col bg-muted/50">
        <div class="border-b p-4">
          <h3 class="font-semibold">Explorer</h3>
        </div>
        <div class="flex-1 p-4">
          <div class="space-y-2">
            <div class="text-sm">📁 src</div>
            <div class="ml-4 text-sm">📄 App.svelte</div>
            <div class="ml-4 text-sm">📄 main.js</div>
          </div>
        </div>
      </div>
    </Resizable.Pane>
    
    <Resizable.Handle />
    
    <!-- Main Content Area -->
    <Resizable.Pane defaultSize={60}>
      <Resizable.PaneGroup direction="vertical">
        <!-- Editor -->
        <Resizable.Pane defaultSize={70}>
          <div class="flex h-full flex-col">
            <div class="border-b p-2">
              <div class="text-sm">App.svelte</div>
            </div>
            <div class="flex-1 p-4 font-mono text-sm">
              <pre>{`<script>
  import { onMount } from 'svelte';
  
  let count = 0;
</script>

<h1>Hello World</h1>
<button on:click={() => count++}>
  Count: {count}
</button>`}</pre>
            </div>
          </div>
        </Resizable.Pane>
        
        <Resizable.Handle />
        
        <!-- Terminal -->
        <Resizable.Pane defaultSize={30} minSize={20}>
          <div class="flex h-full flex-col bg-black text-white">
            <div class="border-b border-gray-700 p-2">
              <div class="text-sm">Terminal</div>
            </div>
            <div class="flex-1 p-4 font-mono text-sm">
              <div>$ bun run dev</div>
              <div class="text-green-400">✓ Server running on localhost:5173</div>
            </div>
          </div>
        </Resizable.Pane>
      </Resizable.PaneGroup>
    </Resizable.Pane>
    
    <Resizable.Handle />
    
    <!-- Right Sidebar -->
    <Resizable.Pane defaultSize={20} minSize={15}>
      <div class="flex h-full flex-col bg-muted/50">
        <div class="border-b p-4">
          <h3 class="font-semibold">Properties</h3>
        </div>
        <div class="flex-1 p-4">
          <div class="space-y-2 text-sm">
            <div>Width: 100%</div>
            <div>Height: auto</div>
            <div>Margin: 0</div>
          </div>
        </div>
      </div>
    </Resizable.Pane>
  </Resizable.PaneGroup>
</div>
```

## Props

### PaneGroup
- `direction` - Layout direction ('horizontal' or 'vertical')
- `class` - Additional CSS classes

### Pane
- `defaultSize` - Default size as percentage
- `minSize` - Minimum size as percentage
- `maxSize` - Maximum size as percentage
- `collapsible` - Allow pane to collapse
- `collapsedSize` - Size when collapsed
- `class` - Additional CSS classes

### Handle
- `withHandle` - Show handle icon
- `disabled` - Disable resizing
- `class` - Additional CSS classes

## Documentation

- [Official Resizable Documentation](https://www.shadcn-svelte.com/docs/components/resizable)
- [React Resizable Panels Documentation](https://github.com/bvaughn/react-resizable-panels)
