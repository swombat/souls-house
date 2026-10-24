class CompanionBodyExpiryJob < ApplicationJob

  def perform(body_id)
    CompanionOperationBody.where(id: body_id).where(expires_at: ..Time.current).delete_all
  end

end
