# Textarea Component

## Installation

```bash
bunx shadcn-svelte@latest add textarea
```

## Usage

```svelte
<script>
  import { Textarea } from "$lib/components/ui/textarea";
  import { Label } from "$lib/components/ui/label";
  
  let message = "";
</script>

<!-- Basic textarea -->
<Textarea placeholder="Type your message here." />

<!-- With label -->
<div class="grid w-full gap-1.5">
  <Label for="message">Your message</Label>
  <Textarea placeholder="Type your message here." id="message" />
</div>

<!-- Controlled with binding -->
<Textarea 
  bind:value={message} 
  placeholder="Enter your feedback" 
/>
<p class="text-sm text-muted-foreground">
  {message.length}/500 characters
</p>

<!-- Custom rows -->
<Textarea rows={10} placeholder="Write a longer text..." />

<!-- Disabled state -->
<Textarea disabled placeholder="This textarea is disabled" />

<!-- With character limit -->
<Textarea 
  maxlength={500}
  placeholder="Maximum 500 characters" 
/>
```

## Props

- `placeholder` - Placeholder text
- `rows` - Number of visible text lines
- `disabled` - Disable textarea
- `readonly` - Make textarea read-only
- `value` - Textarea value (for binding)
- `class` - Additional CSS classes
- `id` - Textarea ID for label association
- `name` - Form field name
- `required` - Mark as required field
- `maxlength` - Maximum character length
- `minlength` - Minimum character length

## Common Patterns

### Character Counter
```svelte
<script>
  let text = "";
  const maxLength = 280;
</script>

<div class="space-y-2">
  <Textarea 
    bind:value={text}
    maxlength={maxLength}
    placeholder="What's on your mind?"
  />
  <div class="text-sm text-muted-foreground text-right">
    {text.length}/{maxLength}
  </div>
</div>
```

## Documentation

- [Official Textarea Documentation](https://www.shadcn-svelte.com/docs/components/textarea)
