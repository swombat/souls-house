<script>
  import { router } from '@inertiajs/svelte';
  import { useSync } from '$lib/use-sync';
  import { Button } from '$lib/components/shadcn/button';
  import FeatureToggleSettingsCard from '$lib/components/admin/FeatureToggleSettingsCard.svelte';
  import SiteIdentitySettingsCard from '$lib/components/admin/SiteIdentitySettingsCard.svelte';

  let { setting = {}, follow_through_residents = [] } = $props();

  useSync({ 'Setting:all': 'setting' });

  let form = $state({ ...setting });
  let logoFile = $state(null);
  let submitting = $state(false);

  function handleLogoChange(e) {
    logoFile = e.target.files?.[0] || null;
  }

  function handleSubmit() {
    if (submitting) return;
    submitting = true;

    const formData = new FormData();
    formData.append('setting[site_name]', form.site_name);
    formData.append('setting[allow_signups]', form.allow_signups);
    formData.append('setting[max_accounts]', form.max_accounts ?? 30);
    formData.append('setting[allow_chats]', form.allow_chats);
    formData.append('setting[allow_agents]', form.allow_agents);
    formData.append('setting[show_usage_in_chat]', form.show_usage_in_chat);
    formData.append('setting[follow_through_residents]', form.follow_through_residents ?? '');

    if (logoFile) {
      formData.append('setting[logo]', logoFile);
    }

    router.patch('/admin/settings', formData, {
      onFinish: () => {
        submitting = false;
        logoFile = null;
      },
    });
  }

  function handleRemoveLogo() {
    if (!confirm('Remove the site logo?')) return;

    const formData = new FormData();
    formData.append('setting[remove_logo]', 'true');

    router.patch('/admin/settings', formData);
  }
</script>

<div class="p-8 max-w-4xl mx-auto">
  <h1 class="text-3xl font-bold mb-2">Site Settings</h1>
  <p class="text-muted-foreground mb-8">Configure global site settings and feature toggles</p>

  <form
    onsubmit={(e) => {
      e.preventDefault();
      handleSubmit();
    }}>
    <div class="space-y-6">
      <SiteIdentitySettingsCard
        {setting}
        {form}
        {logoFile}
        onLogoChange={handleLogoChange}
        onRemoveLogo={handleRemoveLogo} />
      <FeatureToggleSettingsCard {form} />

      <div class="rounded-lg border p-6 space-y-2">
        <label for="max_accounts" class="font-medium">Maximum accounts</label>
        <input
          id="max_accounts"
          class="block h-10 w-28 rounded-md border bg-background px-3"
          type="number"
          min="0"
          step="1"
          required
          bind:value={form.max_accounts} />
        <p class="text-sm text-muted-foreground">
          Counts all personal and team accounts, including disabled accounts. At the limit, new signups and account
          creation close for everyone except site admins. Existing accounts keep working. Set 0 to close admission.
        </p>
      </div>

      <div class="rounded-lg border p-6 space-y-2">
        <label for="follow_through_residents" class="font-medium">Follow-through check</label>
        <input
          id="follow_through_residents"
          class="block h-10 w-full rounded-md border bg-background px-3 font-mono text-sm"
          type="text"
          placeholder="Off"
          bind:value={form.follow_through_residents} />
        <p class="text-sm text-muted-foreground">
          A minute after a resident's run ends on a promise it didn't keep, the house wakes it once to finish. List the
          residents to check, by the id in their URL, separated by commas, or write <code>all</code>. Leave empty to
          turn it off. Ask a resident before switching it on for them.
        </p>
        {#if follow_through_residents.length > 0}
          <ul class="text-sm space-y-1" data-testid="follow-through-residents">
            {#each follow_through_residents as resident}
              <li>
                <code>{resident.id}</code>
                {#if resident.name}
                  · {resident.name}{resident.account ? ` (${resident.account})` : ''}
                {:else}
                  · <span class="text-destructive">no resident with this id</span>
                {/if}
              </li>
            {/each}
          </ul>
        {/if}
      </div>

      <div class="flex justify-end">
        <Button type="submit" disabled={submitting}>
          {submitting ? 'Saving...' : 'Save Settings'}
        </Button>
      </div>
    </div>
  </form>
</div>
