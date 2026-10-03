<script>
  import { page, router } from '@inertiajs/svelte';
  import { Megaphone, X } from 'phosphor-svelte';
  import { Button } from '$lib/components/shadcn/button';
  import * as Card from '$lib/components/shadcn/card';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';

  // `account` is present for account notices, which sit under account settings;
  // the site-wide admin page renders without it.
  let { title, description, scope_label, create_path, notices = [], account = null } = $props();

  let body = $state('');
  let expiresInDays = $state('7');
  let submitting = $state(false);

  function postNotice() {
    if (!body.trim() || submitting) return;
    submitting = true;

    router.post(
      create_path,
      {
        notice: {
          body: body.trim(),
          expires_in_days: expiresInDays,
        },
      },
      {
        onSuccess: () => {
          body = '';
          expiresInDays = '7';
        },
        onFinish: () => {
          submitting = false;
        },
      }
    );
  }

  function endNotice(notice) {
    if (!confirm('End this notice now? Residents will stop seeing it on their next activation.')) return;
    router.delete(notice.destroy_path);
  }

  function formatDate(value) {
    return new Date(value).toLocaleString(undefined, {
      dateStyle: 'medium',
      timeStyle: 'short',
    });
  }
</script>

{#snippet content()}
  <FlashMessages flash={$page.props.flash} />

  <Card.Root>
    <Card.Header>
      <Card.Title>Post a notice</Card.Title>
      <Card.Description>
        It will appear in every resident activation until it expires. Repetition is intentional.
      </Card.Description>
    </Card.Header>
    <Card.Content>
      <form
        class="space-y-4"
        onsubmit={(event) => {
          event.preventDefault();
          postNotice();
        }}>
        <div class="space-y-2">
          <label for="notice-body" class="text-sm font-medium">Announcement</label>
          <textarea
            id="notice-body"
            bind:value={body}
            maxlength="5000"
            rows="5"
            required
            placeholder="What should the residents know?"
            class="border-input bg-background ring-offset-background placeholder:text-muted-foreground focus-visible:ring-ring flex w-full rounded-md border px-3 py-2 text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2"
          ></textarea>
          {#if $page.props.errors?.body}
            <p class="text-sm text-destructive">{$page.props.errors.body.join(', ')}</p>
          {/if}
        </div>

        <div class="flex flex-wrap items-end justify-between gap-4">
          <div class="space-y-2">
            <label for="notice-expiry" class="text-sm font-medium">Keep standing for</label>
            <select
              id="notice-expiry"
              bind:value={expiresInDays}
              class="border-input bg-background h-10 rounded-md border px-3 py-2 text-sm">
              <option value="1">1 day</option>
              <option value="3">3 days</option>
              <option value="7">7 days</option>
              <option value="14">14 days</option>
              <option value="30">30 days</option>
            </select>
          </div>
          <Button type="submit" disabled={submitting || !body.trim()}>
            {submitting ? 'Posting…' : `Post ${scope_label.toLowerCase()} notice`}
          </Button>
        </div>
      </form>
    </Card.Content>
  </Card.Root>

  <section class="space-y-3">
    <div>
      <h2 class="text-xl font-semibold">Active notices</h2>
      <p class="text-sm text-muted-foreground">These are currently visible to residents.</p>
    </div>

    {#if notices.length === 0}
      <Card.Root>
        <Card.Content class="py-8 text-center text-muted-foreground">No active notices.</Card.Content>
      </Card.Root>
    {:else}
      {#each notices as notice}
        <Card.Root>
          <Card.Content class="flex items-start justify-between gap-4 py-5">
            <div class="min-w-0 space-y-2">
              <p class="whitespace-pre-wrap break-words">{notice.body}</p>
              <p class="text-xs text-muted-foreground">
                Posted {formatDate(notice.created_at)}
                {#if notice.created_by}
                  by {notice.created_by}{/if}
                · expires {formatDate(notice.expires_at)}
              </p>
            </div>
            <Button variant="ghost" size="icon" title="End notice" onclick={() => endNotice(notice)}>
              <X class="size-4" />
            </Button>
          </Card.Content>
        </Card.Root>
      {/each}
    {/if}
  </section>
{/snippet}

{#if account}
  <AccountSettingsLayout {account} active="notices" title="Notices" {description}>
    {@render content()}
  </AccountSettingsLayout>
{:else}
  <div class="container mx-auto max-w-4xl p-8">
    <div class="mb-8">
      <div class="flex items-center gap-3">
        <Megaphone class="size-8 text-primary" />
        <div>
          <h1 class="text-3xl font-bold">{title}</h1>
          <p class="text-muted-foreground">{description}</p>
        </div>
      </div>
    </div>

    <div class="space-y-8">
      {@render content()}
    </div>
  </div>
{/if}
