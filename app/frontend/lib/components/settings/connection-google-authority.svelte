<script>
  import { Button } from '$lib/components/shadcn/button';
  import { submitNativePost } from '$lib/integration-forms';
  import ServiceAuthoritySelector from '$lib/components/service-authority-selector.svelte';
  let { connection, services, account } = $props();
  let connectionAuthoritySelections = $state({});
  let editingConnections = $state({});
  function connectionAuthority(connection) {
    return connectionAuthoritySelections[connection.id] || connection.effective_authority || {};
  }

  function updateConnectionAuthority(connection, selection) {
    connectionAuthoritySelections = { ...connectionAuthoritySelections, [connection.id]: selection };
  }

  function reconnectGoogle(connection, service) {
    if (!confirm('Changing Google access temporarily disconnects it from residents while you consent again. Continue?'))
      return;
    submitNativePost(`/accounts/${account.id}/service_authorizations`, {
      provider: service.key,
      management_scope: connection.management_scope,
      service_connection_id: connection.id,
      authority_selection: JSON.stringify(connectionAuthority(connection)),
    });
  }

  function serviceFor(connection) {
    return services.find((service) => service.key === connection.provider);
  }

  function shortScope(scope) {
    return scope
      .replace('https://www.googleapis.com/auth/', '')
      .replace('https://mail.google.com/', 'mail')
      .replace('https://www.googleapis.com/', '');
  }

  function visibleScopes(connection) {
    return (connection.granted_scopes || [])
      .map(shortScope)
      .filter((scope) => !['openid', 'userinfo.email', 'email'].includes(scope));
  }

  function editingConnection(connection) {
    return editingConnections[connection.id] || connection.status === 'reauthorizing';
  }

  function editConnection(connection) {
    editingConnections = { ...editingConnections, [connection.id]: true };
  }

  function cancelEditingConnection(connection) {
    const next = { ...editingConnections };
    delete next[connection.id];
    editingConnections = next;
    const selections = { ...connectionAuthoritySelections };
    delete selections[connection.id];
    connectionAuthoritySelections = selections;
  }
</script>

{#if connection.provider === 'google_workspace'}
  {@const googleService = serviceFor(connection)}
  <div class="space-y-3">
    {#if visibleScopes(connection).length > 0}
      <div class="flex flex-wrap gap-1.5">
        {#each visibleScopes(connection) as scope}
          <span class="rounded-full bg-muted px-2.5 py-1 font-mono text-xs">{scope}</span>
        {/each}
      </div>
    {/if}
    {#each connection.authority_warnings || [] as warning}
      <p class="text-xs text-amber-700">{warning}</p>
    {/each}
    {#if googleService && connection.can_manage}
      {#if editingConnection(connection)}
        <div class="space-y-4 rounded-lg border bg-muted/20 p-4">
          <ServiceAuthoritySelector
            service={googleService}
            selection={connectionAuthority(connection)}
            onchange={(selection) => updateConnectionAuthority(connection, selection)} />
          <div class="flex justify-end gap-2">
            {#if connection.status !== 'reauthorizing'}
              <Button type="button" variant="ghost" size="sm" onclick={() => cancelEditingConnection(connection)}>
                Cancel
              </Button>
            {/if}
            <Button type="button" size="sm" onclick={() => reconnectGoogle(connection, googleService)}>
              {connection.status === 'reauthorizing' ? 'Finish reconnecting' : 'Save and reconnect'}
            </Button>
          </div>
        </div>
      {:else}
        <Button type="button" variant="outline" size="sm" onclick={() => editConnection(connection)}>
          Edit access
        </Button>
      {/if}
    {/if}
  </div>
{/if}
