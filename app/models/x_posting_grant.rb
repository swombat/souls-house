# One resident's permission to post to its account's X handle, switched on
# and off from the Integrations page. No row, no posting.
class XPostingGrant < ApplicationRecord

  belongs_to :x_integration
  belongs_to :agent

  validates :agent_id, uniqueness: { scope: :x_integration_id }
  validate :agent_lives_in_the_integrations_account

  private

  def agent_lives_in_the_integrations_account
    return unless agent && x_integration
    return if agent.account_id == x_integration.account_id

    errors.add(:agent, "must be a resident of the account the X handle belongs to")
  end

end
