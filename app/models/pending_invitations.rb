# Invitations waiting for a person to accept, across every enabled account
# that has invited them. Shown in the navbar as an envelope with a count beside
# the reply-attention and expired-subscription badges, with an Accept for each
# in the account menu. Until this, an invitation to someone who already had an
# account lived only in the email (Daniel, 2026-10-27, jEDROe: Pepe had
# invited him and nothing in the app said so).
class PendingInvitations

  def self.summary_for(user)
    new(user).summary
  end

  def self.scope_for(user)
    user.memberships.pending_invitations.joins(:account).merge(Account.enabled)
  end

  def initialize(user)
    @user = user
  end

  def summary
    items = self.class.scope_for(@user).includes(:account, :invited_by).order(:created_at).map { |m| item_for(m) }
    { total: items.size, items: items }
  end

  private

  def item_for(membership)
    inviter = membership.invited_by
    {
      id: membership.to_param,
      account_name: membership.account.name,
      role: membership.role,
      invited_by: inviter&.full_name.presence || inviter&.email_address,
      invited_at: membership.created_at.iso8601
    }
  end

end
