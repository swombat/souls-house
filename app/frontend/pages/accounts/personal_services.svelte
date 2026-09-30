<script>
  import PersonalServiceConnect from '$lib/components/settings/personal-service-connect.svelte';
  import PersonalServiceConnection from '$lib/components/settings/personal-service-connection.svelte';
  import { serviceDescription } from '$lib/service-presentation';

  import { Button } from '$lib/components/shadcn/button/index.js';

  import { DropboxLogo, GithubLogo, GoogleLogo, Heartbeat, ArrowLeft } from 'phosphor-svelte';

  let { account, services = [], connections = [], focused_service: focusedService = null } = $props();
</script>

<svelte:head><title>Personal Services</title></svelte:head>

<div class="container mx-auto max-w-6xl space-y-8 p-8">
  {#if focusedService}
    <a
      href={`/accounts/${account.id}/personal_services`}
      class="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground">
      <ArrowLeft size={16} /> Personal Services
    </a>
    <div class="max-w-2xl space-y-6">
      <div>
        <h1 class="text-3xl font-bold">Connect {focusedService.name}</h1>
        <p class="mt-2 text-muted-foreground">{serviceDescription(focusedService)}</p>
      </div>
      <PersonalServiceConnect {account} {focusedService} />
    </div>
  {:else}
    <a href="/user/edit" class="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground">
      <ArrowLeft size={16} /> User settings
    </a>
    <div>
      <h1 class="text-3xl font-bold">Personal Services</h1>
      <p class="mt-2 text-muted-foreground">
        Connect your own external identities to {account.name}, then choose which residents may use them.
      </p>
    </div>

    <section class="space-y-3 rounded-xl border bg-muted/20 p-4">
      <h2 class="text-sm font-semibold">Connect new…</h2>
      <div class="flex flex-wrap gap-2">
        {#each services as service}
          <Button variant="outline" href={`/accounts/${account.id}/personal_services?connect=${service.key}`}>
            {#if service.key === 'dropbox'}
              <DropboxLogo weight="fill" />
            {:else if service.key === 'google_workspace'}
              <GoogleLogo weight="bold" />
            {:else if service.key === 'github'}
              <GithubLogo weight="fill" />
            {:else}
              <Heartbeat weight="fill" />
            {/if}
            {service.name}
          </Button>
        {/each}
      </div>
      <p class="text-xs text-muted-foreground">
        You can connect more than one service of the same kind—for example, several GitHub repositories or Google
        accounts.
      </p>
    </section>

    <section class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">Connected services</h2>
        <p class="text-sm text-muted-foreground">Manage each connection and choose which residents can use it.</p>
      </div>
      {#if connections.length === 0}
        <p class="rounded-xl border bg-card p-6 text-sm text-muted-foreground">
          No personal services are connected yet.
        </p>
      {/if}
      {#each connections as connection (connection.id)}
        <PersonalServiceConnection {connection} {account} {services} />
      {/each}
    </section>
  {/if}
</div>
