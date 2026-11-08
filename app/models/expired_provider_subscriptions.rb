# Residents whose provider subscription login has expired, across every
# account a person is a confirmed owner or admin of. Shown in the navbar as a black
# count beside the red reply-attention one, so a lapsed Claude or Gemini login
# is visible the moment someone signs in rather than when they happen to open
# the account and see the notice (Daniel, 2026-10-14, AjabgJ).
#
# A connection counts while the resident is still set to draw on it
# (auth mode oauth_account) and it is marked "expired", which is what the
# runtime writes on an auth failure. Reconnecting clears it; switching the
# resident to an API key stops it counting.
#
# Owners and admins (Daniel, 2026-11-08, jZxLnY): reconnecting a lapsed login
# is the job of whoever runs the account, which is not always the person who
# owns it (Daniel runs his father's resident as a member and never saw its
# streak). Plain members of someone else's account are still not shown it,
# which keeps the 27 Oct rule (elXOke) that a guest in Pepe's house does not
# get Pepe's notices. Site admins get nothing from being site admins.
#
# The same black count carries residents whose scheduled runs are failing
# (Daniel, 2026-10-31, YDbPQj: "a black notification like the subscription
# failure... and then they can click on the resident"). Each open streak
# recorded by ScheduledRunFailureNotice adds one, listed under `failing`, for
# the same owners and admins and with the same exclusions the streak itself uses.
#
# And it carries integrations another house wants to share with one of the
# owner's residents, waiting for the owner's approval (JWblqj), listed under
# `awaiting`; each links to the resident's Integrations tab, where the
# decision is made. Those stay owners only, because only an owner can make it.
class ExpiredProviderSubscriptions

  def self.summary_for(user)
    new(user).summary
  end

  def initialize(user)
    @user = user
  end

  def summary
    items = expired_items
    failing = failing_items
    awaiting = awaiting_items
    by_account = Hash.new(0)
    (items + failing + awaiting).each { |item| by_account[item[:account_id]] += 1 }
    { total: items.size + failing.size + awaiting.size, accounts: by_account, items: items, failing: failing, awaiting: awaiting }
  end

  private

  def awaiting_items
    AgentServiceAccess.awaiting_home_approval
      .joins(:agent).where(agents: { account_id: owned_account_ids(Membership.owners) })
      .includes(agent: :account, service_connection: :account)
      .order(:home_approval_requested_at)
      .map do |access|
        agent = access.agent
        connection = access.service_connection
        {
          key: "guest-access-#{access.id}",
          account_id: agent.account.to_param,
          account_name: agent.account.name,
          agent_id: agent.to_param,
          agent_name: agent.name,
          connection_label: connection.display_label,
          provider_name: connection.definition.name,
          sharing_account_name: connection.account.name,
          url: Rails.application.routes.url_helpers.edit_account_agent_path(agent.account, agent, tab: "integrations")
        }
      end
  end

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
    Agent.where(account_id: owned_account_ids(Membership.admins))
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

  def failing_items
    agents = Agent.where(account_id: owned_account_ids(Membership.admins), active: true)
      .where.not(runtime: Agent::RuntimeAvailability::RETIRED_RUNTIMES)
    ids = agents.pluck(:id)
    return [] if ids.empty?

    streaks = AuditLog.where(action: ScheduledRunFailureNotice::FAILING, auditable_type: "Agent", auditable_id: ids)
    closed = AuditLog.where(action: ScheduledRunFailureNotice::RECOVERED, auditable_type: "Agent", auditable_id: ids)
      .pluck(Arel.sql("data->>'streak_id'")).compact.map(&:to_i)
    open_ids = streaks.where.not(id: closed).order(:id).index_by(&:auditable_id)
    return [] if open_ids.empty?

    agents.where(id: open_ids.keys).includes(:account).order(:account_id, :name)
      .reject { |agent| agent.billing_held? || ResidentSwitchedOffNotice.open_holds(agent).exists? }
      .map { |agent| failing_item_for(agent, open_ids.fetch(agent.id)) }
  end

  def failing_item_for(agent, streak)
    category = latest_failure_category(agent) || streak.data&.dig("category").presence || "unknown"
    {
      account_id: agent.account.to_param,
      account_name: agent.account.name,
      agent_id: agent.to_param,
      agent_name: agent.name,
      cause: RunFailureNotice::NO_REPLY_CAUSES.fetch(category, RunFailureNotice::NO_REPLY_CAUSES.fetch("unknown")),
      url: Rails.application.routes.url_helpers.edit_account_agent_path(agent.account, agent, tab: "interactions")
    }
  end

  # The cause of the newest failed scheduled run, not the one stored when
  # the streak opened: a streak that opened as a plain runtime error and is
  # now failing on a classified refusal says so (#678). Nil when the newest
  # finished scheduled run didn't fail (its recovery row is on its way).
  def latest_failure_category(agent)
    latest = Agents::RunFailureStreak.scheduled_scope(agent.agent_runtime_interactions.where.not(finished_at: nil))
      .order(finished_at: :desc, id: :desc).first
    latest&.failure_category
  end

  # Expired logins and failing runs go to owners and admins; a waiting
  # guest-access request goes to owners only, because only an owner can
  # decide it (Agents::GuestAccessApprovalsController).
  def owned_account_ids(roles)
    @user.confirmed_accounts.merge(roles).select(:id)
  end

  def item_for(agent, provider)
    {
      account_id: agent.account.to_param,
      account_name: agent.account.name,
      agent_id: agent.to_param,
      agent_name: agent.name,
      provider: provider,
      provider_name: Agents::ProviderSubscriptionPresentation::PROVIDER_NAMES.fetch(provider, provider.to_s.titleize),
      url: Rails.application.routes.url_helpers.edit_account_agent_path(agent.account, agent, tab: "settings")
    }
  end

end
