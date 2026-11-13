class AllowanceBrakeNotice < ApplicationRecord

  belongs_to :agent

  def self.record!(agent:, provider:, window:)
    reset = window["resets_at"]
    # Without a provider reset/id, announce at most once for this resident and
    # provider, ever. Do not invent a calendar period or use observation time.
    key = if reset.present? && window["id"].present?
      Digest::SHA256.hexdigest("#{window['id']}/#{reset}")
    else
      "unknown-window"
    end
    row = create_or_find_by!(agent: agent, provider: provider, window_key: key) do |notice|
      notice.resets_at = Time.iso8601(reset) if reset.present?
    end
    return unless row.previously_new_record?

    ActiveRecord.after_all_transactions_commit do
      ResidentHealthMailer.allowance_braked(row).deliver_later if agent.account.owner
    end
  end

end
