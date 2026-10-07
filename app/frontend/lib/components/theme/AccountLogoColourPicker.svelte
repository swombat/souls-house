<script>
  import { router } from '@inertiajs/svelte';
  import { cn } from '$lib/utils.js';

  // Same default as --account-dot in application.css and the logo SVG's fallback.
  const DEFAULT_DOT = '#f15d61';

  // current: the account's stored colour name, or null for the default coral.
  let { accountId, current = null, options = [], canManage = false } = $props();
  let saving = $state(false);

  function choose(colour) {
    if (!canManage || saving || colour === current) return;
    saving = true;
    router.patch(
      `/accounts/${accountId}/interface`,
      { account: { logo_colour: colour ?? '' } },
      { preserveScroll: true, onFinish: () => (saving = false) }
    );
  }

  function label(name) {
    return name.charAt(0).toUpperCase() + name.slice(1);
  }
</script>

<div class="flex flex-wrap gap-3" role="radiogroup" aria-label="Logo colour" data-testid="account-logo-colour-picker">
  {#each [null, ...options] as name (name ?? 'default')}
    {@const selected = (current ?? null) === name}
    <button
      type="button"
      role="radio"
      aria-checked={selected}
      aria-label={name ? label(name) : 'Coral (default)'}
      title={name ? label(name) : 'Coral (default)'}
      disabled={!canManage || saving}
      onclick={() => choose(name)}
      data-account-colour={name ?? undefined}
      class={cn(
        'flex flex-col items-center gap-1 rounded-lg p-1 text-xs text-muted-foreground disabled:cursor-default',
        selected ? 'text-foreground' : ''
      )}>
      <span
        class={cn(
          'block h-8 w-8 rounded-full',
          selected ? 'ring-2 ring-ring ring-offset-2 ring-offset-background' : ''
        )}
        style={name ? 'background-color: var(--account-dot)' : `background-color: ${DEFAULT_DOT}`}></span>
      <span>{name ? label(name) : 'Coral'}</span>
    </button>
  {/each}
</div>
