# Residents whose provider subscription login has expired, across every
# account a person is a confirmed member of. Shown in the navbar as a black
# count beside the red reply-attention one, so a lapsed Claude or Gemini login
# is visible the moment someone signs in rather than when they happen to open
# the account and see the notice (Daniel, 2026-10-14, AjabgJ).
#
# A connection counts while the resident is still set to draw on it
# (auth mode oauth_account) and it is marked "expired", which is what the
# runtime writes on an auth failure. Reconnecting clears it; switching the
# resident to an API key stops it counting.
class ExpiredProviderSubscriptions

  def self.summary_for(user)
    new(user).summary
  end

  def initialize(user)
    @user = user
  end

  def summary
    items = expired_items
    by_account = Hash.new(0)
    items.each { |item| by_account[item[:account_id]] += 1 }
    { total: items.size, accounts: by_account, items: items }
  end

  private

  def expired_items
    candidates.flat_map do |agent|
      agent.provider_connections.to_h.filter_map do |provider, connection|
        next unless connection.is_a?(Hash) && connection["status"] == "expired"
        next unless agent.provider_auth_mode(provider) == "oauth_account"

        item_for(agent, provider)
      end
    end
  end

  def candidates
    Agent.where(account_id: @user.confirmed_accounts.select(:id))
      .where.not(runtime: Agent::RuntimeAvailability::RETIRED_RUNTIMES)
      .where(<<~SQL.squish)
        EXISTS (
          SELECT 1 FROM jsonb_each(agents.provider_connections) AS c(key, value)
          WHERE jsonb_typeof(c.value) = 'object' AND c.value->>'status' = 'expired'
        )
      SQL
      .includes(:account)
      .order(:account_id, :name)
  end

  def item_for(agent, provider)
    {
      account_id: agent.account.to_param,
      account_name: agent.account.name,
      agent_id: agent.to_param,
      agent_name: agent.name,
      provider: provider,
      provider_name: Agents::ProviderSubscriptionPresentation::PROVIDER_NAMES.fetch(provider, provider.to_s.titleize),
      url: Rails.application.routes.url_helpers.edit_account_agent_path(agent.account, agent, tab: "hosting")
    }
  end

end
