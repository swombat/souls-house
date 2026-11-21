# Every reply a pocket device was sent in the last AUDIO_WINDOW, so a later
# reply never makes an earlier one's voice unfetchable, and the transcript
# rows each run was certainly shown, so a reply only covers clips it read
# (Mira, #1083).
class AddPocketRepliesToCompanionDevices < ActiveRecord::Migration[8.0]

  def up
    add_column :companion_devices, :pocket_replies, :jsonb, default: [], null: false
    add_column :agent_runtime_interactions, :shown_message_ids, :jsonb, default: [], null: false
    # The last reply before this deploy keeps the rest of its window
    # (datetime columns hold UTC wall time, so no zone conversion).
    execute <<~SQL.squish
      UPDATE companion_devices
      SET pocket_replies = jsonb_build_array(jsonb_build_object(
        'reply_id', pocket_reply_message_id, 'submission_id', pocket_reply_submission_id,
        'at', to_char(pocket_replied_at, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')))
      WHERE kind = 'pocket' AND pocket_reply_message_id IS NOT NULL AND pocket_replied_at IS NOT NULL
    SQL
  end

  def down
    remove_column :agent_runtime_interactions, :shown_message_ids
    remove_column :companion_devices, :pocket_replies
  end

end
