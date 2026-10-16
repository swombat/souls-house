<script>
  import { router } from '@inertiajs/svelte';
  import { useSync } from '$lib/use-sync';
  import { Button } from '$lib/components/shadcn/button';
  import FeatureToggleSettingsCard from '$lib/components/admin/FeatureToggleSettingsCard.svelte';
  import SiteIdentitySettingsCard from '$lib/components/admin/SiteIdentitySettingsCard.svelte';
  import FollowThroughSettingsCard from '$lib/components/admin/FollowThroughSettingsCard.svelte';
  import StalledSweepSettingsCard from '$lib/components/admin/StalledSweepSettingsCard.svelte';
  import VmBirthSettingsCard from '$lib/components/admin/VmBirthSettingsCard.svelte';
  import FieldOcrSettingsCard from '$lib/components/admin/FieldOcrSettingsCard.svelte';
  import FieldTweetsSettingsCard from '$lib/components/admin/FieldTweetsSettingsCard.svelte';

  let { setting = {}, follow_through_residents = [], vm_births = {}, field_ocr = {}, field_tweets = {} } = $props();

  useSync({ 'Setting:all': 'setting' });

  let form = $state({ ...setting });
  let followThroughPicked = $state(follow_through_residents.filter((r) => r.follow_through).map((r) => r.id));
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
    formData.append('setting[safeguard_conversations_enabled]', form.safeguard_conversations_enabled ?? false);
    formData.append('setting[follow_through_scope]', form.follow_through_scope ?? 'off');
    formData.append('setting[stalled_sweep_minutes]', form.stalled_sweep_minutes ?? 0);
    formData.append('setting[new_residents_on_vm]', form.new_residents_on_vm ?? false);
    formData.append('setting[vm_resident_limit]', form.vm_resident_limit ?? 0);
    formData.append('setting[field_ocr_enabled]', form.field_ocr_enabled ?? false);
    formData.append('setting[field_ocr_daily_usd_ceiling]', form.field_ocr_daily_usd_ceiling ?? 1);
    formData.append('setting[field_tweets_enabled]', form.field_tweets_enabled ?? false);
    formData.append('setting[field_tweets_site_monthly_usd_ceiling]', form.field_tweets_site_monthly_usd_ceiling ?? 0);
    formData.append('setting[field_tweets_account_monthly_usd_ceiling]', form.field_tweets_account_monthly_usd_ceiling ?? 1);
    formData.append('setting[field_tweets_daily_import_cap]', form.field_tweets_daily_import_cap ?? 50);
    formData.append('setting[field_tweets_poll_minutes]', form.field_tweets_poll_minutes ?? 15);
    if (form.field_tweets_resume_house) formData.append('setting[field_tweets_resume_house]', 'true');
    formData.append('setting[follow_through_resident_ids][]', '');
    for (const id of followThroughPicked) formData.append('setting[follow_through_resident_ids][]', id);

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

      <FollowThroughSettingsCard {form} residents={follow_through_residents} bind:picked={followThroughPicked} />
      <StalledSweepSettingsCard {form} />

      <VmBirthSettingsCard {form} status={vm_births} />

      <FieldOcrSettingsCard {form} status={field_ocr} />

      <FieldTweetsSettingsCard {form} status={field_tweets} />

      <div class="flex justify-end">
        <Button type="submit" disabled={submitting}>
          {submitting ? 'Saving...' : 'Save Settings'}
        </Button>
      </div>
    </div>
  </form>
</div>
