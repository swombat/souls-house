class RefreshGlossarySettingsJob < ApplicationJob

  def perform
    Account.enabled.select(:id).find_in_batches do |accounts|
      GlossaryActivity.refresh!(accounts.map(&:id))
    end
  end

end
