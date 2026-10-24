<script>
  import { useForm } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { Badge } from '$lib/components/shadcn/badge/index.js';
  import DeviceStreamsFrame from '$lib/components/device-streams/DeviceStreamsFrame.svelte';
  import { ArrowLeft, ArrowRight, Pulse } from 'phosphor-svelte';

  let { account = null, create_url: createUrl = null, recovery_url: recoveryUrl, streams = [] } = $props();

  const form = useForm({ name: '' });

  function create(event) {
    event.preventDefault();
    $form.post(createUrl);
  }
</script>

<svelte:head><title>Device streams</title></svelte:head>

<DeviceStreamsFrame
  {account}
  title={account ? 'Polar H10 / RR stream' : 'Personal device data recovery'}
  description={account
    ? `Publish your own device readings into ${account.name}. A stream holds only your data, and you choose who may read it.`
    : 'Revoke devices or delete your own data across accounts, including accounts you have left.'}>
  <div class="max-w-3xl space-y-6">
    {#if account}
      <a
        href={`/accounts/${account.id}/integrations`}
        class="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground">
        <ArrowLeft size={16} /> Integrations
      </a>

      <section class="rounded-2xl border bg-card p-5 sm:p-6 space-y-4">
        <div>
          <h2 class="text-lg font-semibold">New stream</h2>
          <p class="text-sm text-muted-foreground">
            Create a stream only for your own data in this account. It starts disabled, with no readers other than you.
          </p>
        </div>
        <form onsubmit={create} class="flex flex-col sm:flex-row sm:items-end gap-3">
          <div class="flex-1 space-y-1.5">
            <Label for="stream-name">Stream name</Label>
            <Input
              id="stream-name"
              name="name"
              bind:value={$form.name}
              required
              maxlength={100}
              placeholder="Polar H10" />
          </div>
          <Button type="submit" disabled={$form.processing}>Create disabled stream</Button>
        </form>
      </section>
    {:else}
      <p class="text-sm text-muted-foreground">
        To create a stream or manage readers, open Polar H10 / RR stream from that account's Integrations page.
      </p>
    {/if}

    <section class="space-y-3">
      <h2 class="text-lg font-semibold">Your streams</h2>
      {#if streams.length === 0}
        <p class="rounded-xl border border-dashed p-5 text-sm text-muted-foreground">No streams yet.</p>
      {:else}
        <ul class="divide-y rounded-xl border bg-card">
          {#each streams as stream (stream.url)}
            <li>
              <a href={stream.url} class="group flex items-center gap-3 p-4 hover:bg-muted/50 transition">
                <span class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-rose-600 text-white">
                  <Pulse size={20} weight="bold" />
                </span>
                <span class="min-w-0 flex-1">
                  <span class="block font-medium truncate">{stream.name}</span>
                  <span class="block text-sm text-muted-foreground">{stream.account_name}</span>
                </span>
                {#if stream.erased}
                  <Badge variant="outline">Deleted</Badge>
                {:else if stream.enabled}
                  <Badge>Ingesting</Badge>
                {:else}
                  <Badge variant="secondary">Disabled</Badge>
                {/if}
                <ArrowRight size={16} class="shrink-0 text-muted-foreground group-hover:text-foreground" />
              </a>
            </li>
          {/each}
        </ul>
      {/if}
    </section>

    {#if account}
      <p class="text-sm text-muted-foreground">
        <a href={recoveryUrl} class="underline underline-offset-4 hover:text-foreground"
          >Personal data recovery (all accounts)</a
        >: revoke devices or delete your data even after leaving an account.
      </p>
    {/if}
  </div>
</DeviceStreamsFrame>
