<script>
  import { ShieldWarning } from 'phosphor-svelte';
  import { ADMIN_ONLY_BOX, ADMIN_ONLY_TEXT } from '$lib/admin-only.js';
  import { cn } from '$lib/utils.js';

  // A section only site admins can see. Regular members never get it, so the box
  // tells the admin reviewing a page which parts the people using it don't have.
  let { label = 'Site admins only', class: className = '', children } = $props();
</script>

<div class={cn(ADMIN_ONLY_BOX, className)} data-admin-only>
  <p class={cn('mb-3 flex items-center gap-1.5 text-xs font-medium', ADMIN_ONLY_TEXT)}>
    <ShieldWarning size={14} weight="duotone" />
    {label}
  </p>
  {@render children?.()}
</div>
