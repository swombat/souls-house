<script>
  import UserSettingsForm from '$lib/components/forms/UserSettingsForm.svelte';

  let { user, timezones, colour_options = [], accounts = [], default_account_key = null } = $props();
</script>

<div class="container mx-auto p-8 max-w-6xl">
  <div class="mb-8">
    <div class="flex items-center justify-between">
      <div>
        <h1 class="text-3xl font-bold mb-2">User Settings</h1>
        <p class="text-muted-foreground">Manage your personal information and preferences</p>
      </div>
    </div>
  </div>

  <UserSettingsForm {user} {timezones} {colour_options} {accounts} {default_account_key} />
</div>
