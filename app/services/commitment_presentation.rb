# The commitments a person sees for one resident, with what they may do.
# Used by the resident's own page (home residents) and by the host's
# commitment page for a guest resident (Agents::CommitmentsController#index).
class CommitmentPresentation

  LIMIT = 100

  # Residents from elsewhere, not guests here now, that made commitments in
  # this account: the host's way back to them after a guest leaves.
  def self.former_guests(account:, routes:)
    current = account.guest_memberships.select(:agent_id)
    Agent.where(id: Commitment.where(account_id: account.id).select(:agent_id))
      .where.not(account_id: account.id).where.not(id: current).order(:name)
      .map { |agent| { id: agent.to_param, name: agent.name, commitments_url: routes.account_agent_commitments_path(account, agent) } }
  end

  # The commitments of this resident the viewer may see from this account:
  # for a resident hosted here, those made in any house the viewer belongs
  # to; for a guest, only those made here. Nothing else about a guest is
  # opened by this.
  def self.visible_scope(agent:, account:, viewer:)
    if agent.account_id == account.id
      agent.commitments.where(account_id: viewer.confirmed_accounts.select(:id))
    else
      agent.commitments.where(account_id: account.id)
    end
  end

  def initialize(agent:, account:, viewer:, routes:)
    @agent, @account, @viewer, @routes = agent, account, viewer, routes
  end

  def as_props
    commitments = self.class.visible_scope(agent: @agent, account: @account, viewer: @viewer)
      .includes(:account, :source_chat, :room, :activation_chat, :activation_message, :cancelled_by_user, :cancelled_by_agent)
      .recent_first.limit(LIMIT).to_a
    {
      items: commitments.map do |commitment|
        manageable = commitment.cancellable? && commitment.manageable_by?(@viewer)
        commitment.as_json.merge(
          source_url: commitment.source_chat && @routes.account_chat_path(commitment.account, commitment.source_chat),
          activation_url: commitment.activation_chat && @routes.account_chat_path(commitment.account, commitment.activation_chat),
          manage_url: manageable ? @routes.account_agent_commitment_path(@account, @agent, commitment) : nil
        )
      end
    }
  end

end
