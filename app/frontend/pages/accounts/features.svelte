<script>
  import { page } from '@inertiajs/svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import ResidentHandoffCapCard from '$lib/components/accounts/ResidentHandoffCapCard.svelte';
  import StalledThreadWakeCapCard from '$lib/components/accounts/StalledThreadWakeCapCard.svelte';
  import TelegramBotWakeLimitCard from '$lib/components/accounts/TelegramBotWakeLimitCard.svelte';
  import ReflexesCard from '$lib/components/accounts/ReflexesCard.svelte';
  import ChatCodesCard from '$lib/components/accounts/ChatCodesCard.svelte';
  import RoomChatCountsCard from '$lib/components/accounts/RoomChatCountsCard.svelte';
  import PlanOfferCard from '$lib/components/accounts/PlanOfferCard.svelte';
  import VoiceModeCard from '$lib/components/accounts/VoiceModeCard.svelte';
  import SpeechEngineCard from '$lib/components/accounts/SpeechEngineCard.svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import { createDynamicSync } from '$lib/use-sync';

  // What changes in this account's conversations. A switch the site has
  // fixed for everyone isn't shown: it would do nothing here. A choice the
  // account still has stays (JQvGmY). Voice mode the site has on for everyone
  // keeps its card, without the switch, so where the audio goes stays findable.
  let {
    account,
    can_manage = false,
    resident_handoff_cap = 6,
    stalled_thread_wake_cap = 3,
    telegram_bot_wake_limit = 3,
    reflexes_enabled = false,
    reflexes_site_scope = 'account_choice',
    show_chat_codes = false,
    show_room_chat_counts = false,
    plan_offer_enabled = false,
    plan_offer_available = false,
    voice_mode_enabled = false,
    voice_mode_site_scope = 'account_choice',
    voice_mode_transcription_key = false,
    speech_engine = 'phonon',
    speech_engine_site_scope = 'disabled',
    eleven_labs_key_present = false,
    eleven_labs_house_key = false,
  } = $props();

  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({
      [`Account:${account.id}`]: [
        'account',
        'can_manage',
        'resident_handoff_cap',
        'stalled_thread_wake_cap',
        'telegram_bot_wake_limit',
        'reflexes_enabled',
        'show_chat_codes',
        'show_room_chat_counts',
        'plan_offer_enabled',
        'plan_offer_available',
        'voice_mode_enabled',
        'speech_engine',
        'eleven_labs_key_present',
        'eleven_labs_house_key',
      ],
    });
  });

  const showReflexes = $derived(reflexes_site_scope === 'account_choice');
  const showVoiceMode = $derived(voice_mode_site_scope !== 'disabled');
  const showSpeechEngine = $derived(speech_engine_site_scope === 'account_choice');
  const showPlans = $derived(plan_offer_available || plan_offer_enabled);
</script>

<svelte:head>
  <title>Features · {account.name}</title>
</svelte:head>

<AccountSettingsLayout
  {account}
  active="features"
  title="Features"
  description="What changes in this account's conversations.">
  <FlashMessages flash={$page.props.flash} />

  <section class="space-y-4" aria-labelledby="features-looks">
    <h2 id="features-looks" class="text-xl font-semibold">How it looks</h2>
    <ChatCodesCard accountId={account.id} enabled={show_chat_codes} canManage={can_manage} />
    <RoomChatCountsCard accountId={account.id} enabled={show_room_chat_counts} canManage={can_manage} />
  </section>

  {#if showVoiceMode || showSpeechEngine}
    <section class="space-y-4" aria-labelledby="features-voice">
      <h2 id="features-voice" class="text-xl font-semibold">Voice</h2>
      {#if showVoiceMode}
        <VoiceModeCard
          accountId={account.id}
          enabled={voice_mode_enabled}
          canManage={can_manage}
          siteScope={voice_mode_site_scope}
          transcriptionKey={voice_mode_transcription_key} />
      {/if}
      {#if showSpeechEngine}
        <SpeechEngineCard
          accountId={account.id}
          engine={speech_engine}
          canManage={can_manage}
          siteScope={speech_engine_site_scope}
          keyPresent={eleven_labs_key_present}
          houseKey={eleven_labs_house_key} />
      {/if}
    </section>
  {/if}

  <section class="space-y-4" aria-labelledby="features-residents">
    <h2 id="features-residents" class="text-xl font-semibold">How residents work</h2>
    {#if showPlans}
      <PlanOfferCard
        accountId={account.id}
        enabled={plan_offer_enabled}
        available={plan_offer_available}
        canManage={can_manage} />
    {/if}
    {#if showReflexes}
      <ReflexesCard
        accountId={account.id}
        enabled={reflexes_enabled}
        canManage={can_manage}
        siteScope={reflexes_site_scope} />
    {/if}

    <div class="space-y-4 rounded-xl border border-dashed p-4" data-testid="features-limits">
      <div>
        <h3 class="text-sm font-medium">Limits</h3>
        <p class="text-sm text-muted-foreground">Numbers to leave alone unless something is going wrong.</p>
      </div>
      <ResidentHandoffCapCard accountId={account.id} cap={resident_handoff_cap} canManage={can_manage} />
      <StalledThreadWakeCapCard accountId={account.id} cap={stalled_thread_wake_cap} canManage={can_manage} />
      <TelegramBotWakeLimitCard accountId={account.id} limit={telegram_bot_wake_limit} canManage={can_manage} />
    </div>
  </section>
</AccountSettingsLayout>
