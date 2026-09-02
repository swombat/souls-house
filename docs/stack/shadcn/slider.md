# Slider Component

## Installation

```bash
bunx shadcn-svelte@latest add slider
```

## Usage

```svelte
<script>
  import { Slider } from "$lib/components/ui/slider";
  import { Label } from "$lib/components/ui/label";
  
  let volume = [50];
  let range = [20, 80];
  let price = [100];
</script>

<!-- Basic slider -->
<Slider value={[50]} max={100} step={1} />

<!-- Controlled slider -->
<div class="space-y-2">
  <Label>Volume: {volume[0]}%</Label>
  <Slider bind:value={volume} max={100} step={1} />
</div>

<!-- Range slider -->
<div class="space-y-2">
  <Label>Price Range: ${range[0]} - ${range[1]}</Label>
  <Slider bind:value={range} max={100} step={5} />
</div>

<!-- Custom step -->
<div class="space-y-2">
  <Label>Temperature: {temperature[0]}°C</Label>
  <Slider 
    bind:value={temperature}
    max={40}
    min={-10}
    step={0.5}
  />
</div>

<!-- With marks -->
<div class="space-y-4">
  <Label>Quality</Label>
  <Slider 
    value={[3]}
    max={5}
    step={1}
    class="w-full"
  />
  <div class="flex justify-between text-xs text-muted-foreground">
    <span>Poor</span>
    <span>Fair</span>
    <span>Good</span>
    <span>Great</span>
    <span>Excellent</span>
  </div>
</div>

<!-- Disabled state -->
<Slider value={[50]} max={100} disabled />

<!-- Multiple thumbs -->
<div class="space-y-2">
  <Label>Select range</Label>
  <Slider 
    value={[25, 75]}
    max={100}
    step={1}
    minStepsBetweenThumbs={10}
  />
</div>
```

## Props

- `value` - Array of thumb values
- `max` - Maximum value (default: 100)
- `min` - Minimum value (default: 0)
- `step` - Step increment (default: 1)
- `disabled` - Disable slider
- `orientation` - Slider orientation ('horizontal' | 'vertical')
- `minStepsBetweenThumbs` - Minimum distance between thumbs
- `class` - Additional CSS classes

## Common Patterns

### Volume Control
```svelte
<script>
  import { SpeakerLow, SpeakerHigh, SpeakerX } from "phosphor-svelte";
  let volume = [75];
  
  $: volumeIcon = volume[0] === 0 ? SpeakerX : 
                  volume[0] < 50 ? SpeakerLow : SpeakerHigh;
</script>

<div class="flex items-center space-x-2">
  <svelte:component this={volumeIcon} class="h-4 w-4" />
  <Slider bind:value={volume} max={100} class="flex-1" />
  <span class="w-12 text-sm">{volume[0]}%</span>
</div>
```

### Price Filter
```svelte
<script>
  let priceRange = [0, 1000];
</script>

<div class="space-y-4">
  <div class="flex justify-between">
    <Label>Price Range</Label>
    <span class="text-sm text-muted-foreground">
      ${priceRange[0]} - ${priceRange[1]}
    </span>
  </div>
  <Slider 
    bind:value={priceRange}
    max={1000}
    step={10}
    minStepsBetweenThumbs={50}
  />
  <div class="flex gap-2">
    <Input 
      type="number" 
      bind:value={priceRange[0]} 
      max={priceRange[1] - 50}
      class="w-24"
    />
    <Input 
      type="number" 
      bind:value={priceRange[1]} 
      min={priceRange[0] + 50}
      class="w-24"
    />
  </div>
</div>
```

## Documentation

- [Official Slider Documentation](https://www.shadcn-svelte.com/docs/components/slider)
- [Bits UI Slider](https://bits-ui.com/docs/components/slider)
