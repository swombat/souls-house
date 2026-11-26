class Accounts::FeaturesController < ApplicationController

  # The switches that change what happens in this account's conversations.
  # Each card still saves through AccountsController#update, which sends a
  # feature change back here.
  def show
    account = current_account
    settings = Setting.instance
    render inertia: "accounts/features", props: {
      account: account,
      can_manage: account.manageable_by?(Current.user),
      resident_handoff_cap: account.resident_handoff_cap,
      stalled_thread_wake_cap: account.stalled_thread_wake_cap,
      telegram_bot_wake_limit: account.telegram_bot_wake_limit,
      reflexes_enabled: account.reflexes_enabled,
      reflexes_site_scope: settings.reflexes_scope,
      show_chat_codes: account.show_chat_codes,
      show_room_chat_counts: account.show_room_chat_counts,
      plan_offer_enabled: account.plan_offer_enabled,
      plan_offer_available: account.plan_offer_available?,
      voice_mode_enabled: account.voice_mode_enabled,
      voice_mode_site_scope: settings.voice_mode_scope,
      voice_mode_transcription_key: VoiceMode.transcription_key?(account),
      speech_engine: account.speech_engine,
      speech_engine_site_scope: settings.speech_engine_scope,
      eleven_labs_key_present: account.eleven_labs_api_key.present?,
      eleven_labs_house_key: account.house_eleven_labs_key?
    }
  end

end
