<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Key, Trash } from 'phosphor-svelte';
  import { siteName } from '$lib/branding';

  let { apiKeys = [], onDelete = null, emptyMessage = 'No keys yet.' } = $props();
</script>

<div class="border rounded-lg">
  {#if apiKeys.length === 0}
    <div class="p-8 text-center text-muted-foreground">
      <Key size={48} class="mx-auto mb-4 opacity-50" />
      <p>{emptyMessage}</p>
    </div>
  {:else}
    <div class="divide-y">
      {#each apiKeys as key (key.id)}
        <div class="flex items-center justify-between p-4">
          <div>
            <div class="flex flex-wrap items-center gap-2">
              <span class="font-medium">{key.name}</span>
              {#if key.actor}
                <span class="rounded-full bg-muted px-2 py-0.5 text-xs font-medium">
                  Acts as {key.actor.name}
                </span>
              {/if}
            </div>
            <div class="text-sm text-muted-foreground">
              <code class="bg-muted px-1 rounded">{key.prefix}</code>
              <span class="mx-2">-</span>
              Created {key.created_at}
            </div>
            {#if key.last_used_at}
              <div class="text-xs text-muted-foreground mt-1">
                Last used {key.last_used_at}
              </div>
            {/if}
          </div>
          {#if onDelete}
            <Button variant="ghost" size="icon" aria-label={`Revoke ${key.name}`} onclick={() => onDelete(key.id)}>
              <Trash size={16} class="text-destructive" />
            </Button>
          {:else}
            <span class="text-xs text-muted-foreground">Managed by {$siteName}</span>
          {/if}
        </div>
      {/each}
    </div>
  {/if}
</div>
