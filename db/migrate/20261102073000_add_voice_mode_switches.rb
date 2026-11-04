# Voice mode for conversations (planned in YgDwre, built in YMaddY, 2 Nov
# 2026): a person speaks, each finished utterance becomes an ordinary human
# message, and the residents' replies are read aloud in their chosen voices.
# Three switches, all additive:
# - settings.voice_mode_scope, the three states reflexes use (disabled /
#   account_choice / enabled), defaulting to account_choice as asked;
# - accounts.voice_mode_enabled, each account's own switch, off by default;
# - messages.voice_mode, set on a human turn that was spoken in the mode, so
#   the resident's wake can say the reply will be heard rather than read.
class AddVoiceModeSwitches < ActiveRecord::Migration[8.1]

  def change
    add_column :settings, :voice_mode_scope, :string, default: "account_choice", null: false
    add_column :accounts, :voice_mode_enabled, :boolean, default: false, null: false
    add_column :messages, :voice_mode, :boolean, default: false, null: false
  end

end
