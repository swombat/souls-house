<script>
  import { router } from '@inertiajs/svelte';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import AdminAccountSwitch from './AdminAccountSwitch.svelte';

  // The house's ElevenLabs key for an account without its own
  // (SpeechEngine.eleven_labs_key). Off until a site admin turns it on.
  let { account } = $props();

  function setElevenLabsHouseKey(enabled) {
    router.patch(`/admin/accounts/${account.id}/house_eleven_labs_key`, {
      account: { house_eleven_labs_key: enabled },
    });
  }
</script>

<Card class="mb-8">
  <CardHeader>
    <CardTitle>ElevenLabs voice</CardTitle>
    <CardDescription>
      Accounts that speak with ElevenLabs use their own ElevenLabs key. Turn this on to let this account use the house's
      key instead while it has none. The plan rule still applies (Partners and Colleagues only). A pocket device's
      replies are voiced only under this switch or an account already on ElevenLabs.
    </CardDescription>
  </CardHeader>
  <CardContent>
    <AdminAccountSwitch
      id={`house-eleven-labs-key-${account.id}`}
      label="Use the house ElevenLabs key"
      checked={account.house_eleven_labs_key}
      onCheckedChange={setElevenLabsHouseKey}>
      {account.eleven_labs_own_key
        ? 'This account has its own key, which pays first.'
        : 'This account has no key of its own.'}
      {`${account.house_eleven_labs_characters_30_days || 0} characters on the house key in the last 30 days.`}
    </AdminAccountSwitch>
  </CardContent>
</Card>
