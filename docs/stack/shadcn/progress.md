# Progress Component

## Installation

```bash
bunx shadcn-svelte@latest add progress
```

## Usage

```svelte
<script>
  import { Progress } from "$lib/components/ui/progress";
  
  let value = 13;
</script>

<Progress {value} class="w-[60%]" />
```

## Animated Progress

```svelte
<script>
  import { Progress } from "$lib/components/ui/progress";
  import { onMount } from "svelte";
  
  let value = 0;
  
  onMount(() => {
    const timer = setTimeout(() => value = 66, 500);
    return () => clearTimeout(timer);
  });
</script>

<Progress {value} class="w-[60%]" />
```

## With Label

```svelte
<script>
  import { Progress } from "$lib/components/ui/progress";
  import { Label } from "$lib/components/ui/label";
  
  let value = 32;
</script>

<div class="space-y-2">
  <div class="flex justify-between">
    <Label>Upload Progress</Label>
    <span class="text-sm text-muted-foreground">{value}%</span>
  </div>
  <Progress {value} class="w-full" />
</div>
```

## File Upload Example

```svelte
<script>
  import { Progress } from "$lib/components/ui/progress";
  import { Button } from "$lib/components/ui/button";
  import { Upload } from "phosphor-svelte";
  
  let progress = 0;
  let isUploading = false;
  
  function simulateUpload() {
    isUploading = true;
    progress = 0;
    
    const interval = setInterval(() => {
      progress += Math.random() * 10;
      
      if (progress >= 100) {
        progress = 100;
        isUploading = false;
        clearInterval(interval);
        
        // Reset after showing completion
        setTimeout(() => {
          progress = 0;
        }, 1000);
      }
    }, 200);
  }
</script>

<div class="space-y-4">
  <Button 
    on:click={simulateUpload} 
    disabled={isUploading}
    class="w-full"
  >
    <Upload class="mr-2 h-4 w-4" />
    {isUploading ? 'Uploading...' : 'Upload File'}
  </Button>
  
  {#if progress > 0}
    <div class="space-y-2">
      <div class="flex justify-between text-sm">
        <span>Uploading file.pdf</span>
        <span>{Math.round(progress)}%</span>
      </div>
      <Progress value={progress} class="w-full" />
    </div>
  {/if}
</div>
```

## Multi-Step Progress

```svelte
<script>
  import { Progress } from "$lib/components/ui/progress";
  import { Button } from "$lib/components/ui/button";
  
  let currentStep = 1;
  const totalSteps = 4;
  
  $: progress = (currentStep / totalSteps) * 100;
  
  const steps = [
    "Personal Information",
    "Account Details", 
    "Preferences",
    "Confirmation"
  ];
  
  function nextStep() {
    if (currentStep < totalSteps) {
      currentStep += 1;
    }
  }
  
  function prevStep() {
    if (currentStep > 1) {
      currentStep -= 1;
    }
  }
</script>

<div class="space-y-6">
  <div class="space-y-2">
    <div class="flex justify-between text-sm">
      <span>Step {currentStep} of {totalSteps}</span>
      <span>{Math.round(progress)}% Complete</span>
    </div>
    <Progress value={progress} class="w-full" />
  </div>
  
  <div class="space-y-4">
    <h3 class="text-lg font-semibold">{steps[currentStep - 1]}</h3>
    <p class="text-muted-foreground">
      Complete this step to continue with the setup process.
    </p>
  </div>
  
  <div class="flex justify-between">
    <Button 
      variant="outline" 
      on:click={prevStep}
      disabled={currentStep === 1}
    >
      Previous
    </Button>
    <Button 
      on:click={nextStep}
      disabled={currentStep === totalSteps}
    >
      {currentStep === totalSteps ? 'Finish' : 'Next'}
    </Button>
  </div>
</div>
```

## Props

- `value` - Progress value (0-100)
- `max` - Maximum value (default: 100)
- `class` - Additional CSS classes

## Accessibility

The progress component:
- Uses `role="progressbar"`
- Includes `aria-valuenow`, `aria-valuemin`, and `aria-valuemax` attributes
- Supports screen readers with proper ARIA labels

## Documentation

- [Official Progress Documentation](https://www.shadcn-svelte.com/docs/components/progress)
