<script>
  import { userPath } from '@/routes';
  import { router } from '@inertiajs/svelte';
  import Form from './Form.svelte';
  import Input from '$lib/components/shadcn/input/input.svelte';
  import Label from '$lib/components/shadcn/label/label.svelte';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import AvatarUpload from '$lib/components/AvatarUpload.svelte';
  import Avatar from '$lib/components/Avatar.svelte';
  import ColourPicker from '$lib/components/ColourPicker.svelte';
  import ThemeHuePicker from '$lib/components/theme/ThemeHuePicker.svelte';

  let {
    user,
    timezones,
    colour_options = [],
    accounts = [],
    default_account_key = null,
    onCancel,
    onSuccess,
  } = $props();

  const AUTOMATIC = 'automatic';
  const choosesDefaultAccount = $derived(accounts.length > 1);

  let user_form = $state({ ...user, theme_hue: user.theme_hue ?? null });
  let defaultAccountChoice = $state(default_account_key || AUTOMATIC);
  // The default account is only sent when the choice is on screen.
  const formData = () => ({
    user: choosesDefaultAccount
      ? { ...user_form, default_account_key: defaultAccountChoice === AUTOMATIC ? '' : defaultAccountChoice }
      : user_form,
  });

  function handleAvatarUpdate() {
    // Reload the page to get updated user data
    router.reload({ only: ['user'] });
  }
</script>

<Form
  action={userPath()}
  method="patch"
  data={formData}
  title="Personal Information"
  submitLabel="Save Changes"
  submitLabelProcessing="Saving..."
  wide={true}
  {onCancel}
  {onSuccess}>
  <!-- Avatar section positioned at top right -->
  <div class="flex justify-between items-start mb-6">
    <div>
      <h3 class="text-lg font-semibold">Profile Picture</h3>
      <p class="text-sm text-muted-foreground">Click your avatar to upload or change your profile picture</p>
    </div>
    <AvatarUpload {user} onUpdate={handleAvatarUpdate} />
  </div>
  <!-- Separator line -->
  <div class="border-t my-6"></div>

  <div>
    <Label for="email">Email Address</Label>
    <Input type="email" id="email" value={user_form.email_address} disabled class="bg-gray-50 dark:bg-gray-900" />
    <p class="text-sm text-gray-500 mt-1">Email cannot be changed</p>
  </div>

  <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
    <div>
      <Label for="first_name">First Name</Label>
      <Input
        type="text"
        id="first_name"
        bind:value={user_form.first_name}
        placeholder="Enter your first name"
        required />
    </div>

    <div>
      <Label for="last_name">Last Name</Label>
      <Input type="text" id="last_name" bind:value={user_form.last_name} placeholder="Enter your last name" required />
    </div>
  </div>

  <div>
    <Label for="timezone">Timezone</Label>
    <Select.Root type="single" name="timezone" bind:value={user_form.timezone}>
      <Select.Trigger class="w-full">
        {#if user_form.timezone}
          {timezones.find((tz) => tz.value === user_form.timezone)?.label || user_form.timezone}
        {:else}
          <span class="text-muted-foreground">Select your timezone</span>
        {/if}
      </Select.Trigger>
      <Select.Content>
        {#each timezones as tz}
          <Select.Item value={tz.value}>
            <span class="min-w-48">{tz.label.substring(tz.label.indexOf(' ') + 1)}</span>
            {tz.label.split(' ')[0]}
          </Select.Item>
        {/each}
      </Select.Content>
    </Select.Root>
    <p class="text-sm text-gray-500 mt-1">Type to search for your timezone (e.g., "London")</p>
  </div>

  {#if choosesDefaultAccount}
    <div>
      <Label for="default_account">Default account</Label>
      <Select.Root type="single" name="default_account" bind:value={defaultAccountChoice}>
        <Select.Trigger class="w-full" id="default_account">
          {#if defaultAccountChoice === AUTOMATIC}
            First account you joined
          {:else}
            {accounts.find((a) => a.id === defaultAccountChoice)?.name || 'Account'}
          {/if}
        </Select.Trigger>
        <Select.Content>
          <Select.Item value={AUTOMATIC}>First account you joined</Select.Item>
          {#each accounts as account}
            <Select.Item value={account.id}>{account.name}</Select.Item>
          {/each}
        </Select.Content>
      </Select.Root>
      <p class="text-sm text-gray-500 mt-1">The account you land in after signing in.</p>
    </div>
  {/if}

  <!-- Separator line -->
  <div class="border-t my-6"></div>

  <div>
    <h3 class="text-lg font-semibold mb-2">Chat Appearance</h3>
    <p class="text-sm text-muted-foreground mb-4">Customise how your messages appear in group chats</p>
    <ColourPicker bind:value={user_form.chat_colour} options={colour_options} label="Chat Bubble Colour" />
  </div>

  <div class="border-t my-6"></div>

  <div>
    <h3 class="text-lg font-semibold mb-2">Colour Theme</h3>
    <p class="text-sm text-muted-foreground mb-4">
      A gentle tint for the whole site, just for you. Light mode stays pale and dark mode stays deep.
    </p>
    <ThemeHuePicker bind:value={user_form.theme_hue} saved={user.theme_hue ?? null} />
  </div>
</Form>
