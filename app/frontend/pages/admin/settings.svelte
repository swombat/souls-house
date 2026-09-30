<script>
  import { router } from '@inertiajs/svelte';
  import { useSync } from '$lib/use-sync';
  import { Button } from '$lib/components/shadcn/button';
  import FeatureToggleSettingsCard from '$lib/components/admin/FeatureToggleSettingsCard.svelte';
  import SiteIdentitySettingsCard from '$lib/components/admin/SiteIdentitySettingsCard.svelte';

  let { setting = {} } = $props();

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
    formData.append('setting[safeguard_owner_notice_threshold]', form.safeguard_owner_notice_threshold);

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

      <div class="rounded-lg border bg-card p-6">
        <h2 class="text-lg font-semibold">Safeguard notices</h2>
        <p class="mt-1 text-sm text-muted-foreground">
          Notify the account owner after this many consecutive detections in one Telegram thread.
        </p>
        <p class="mt-1 text-sm text-muted-foreground">
          Notices and weekly digests are sent through the resident's Telegram bot, so the owner must be subscribed to
          that bot.
        </p>
        <label class="mt-4 block text-sm font-medium" for="safeguard_owner_notice_threshold">Detection threshold</label>
        <input
          id="safeguard_owner_notice_threshold"
          class="mt-2 h-10 w-28 rounded-md border bg-background px-3"
          type="number"
          min="1"
          bind:value={form.safeguard_owner_notice_threshold} />
      </div>

      <div class="flex justify-end">
        <Button type="submit" disabled={submitting}>
          {submitting ? 'Saving...' : 'Save Settings'}
        </Button>
      </div>
    </div>
  </form>
</div>
