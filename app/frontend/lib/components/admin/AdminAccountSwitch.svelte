<script>
  // One labelled on/off setting on the admin account page: a name, a line of
  // explanation, and the switch.
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { Switch } from '$lib/components/shadcn/switch/index.js';

  let { id, label, checked = false, onCheckedChange, class: className = '', children } = $props();
</script>

<div class="flex items-center justify-between gap-6 rounded-md border p-4 {className}">
  <div class="space-y-1">
    <Label for={id}>{label}</Label>
    <p class="text-sm text-muted-foreground">{@render children?.()}</p>
  </div>
  <Switch {id} aria-label={label} {checked} {onCheckedChange} />
</div>
