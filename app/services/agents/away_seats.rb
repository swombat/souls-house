module Agents
  # The extra lines on each away seat in the Guest residents card (JwMzAe):
  # how many rhythms the account the resident is a guest in has set up with
  # it, with a link to that account's rhythms when the viewer belongs there,
  # and the runs it has going there right now, for the same spinner as the
  # resident cards. One query for the rhythms, one for the runs.
  class AwaySeats

    def initialize(memberships, user:, routes:)
      @memberships = memberships.to_a
      @user = user
      @routes = routes
    end

    # Each membership's JSON (as given) with a `rhythms` entry added:
    # { count:, url: } where url is nil when the viewer cannot open that
    # account's rhythms page.
    def with_rhythms(rows)
      counts = rhythm_counts
      reachable = reachable_account_ids
      rows.zip(@memberships).map do |row, membership|
        count = counts.fetch([ membership.account_id, membership.agent_id ], 0)
        url = reachable.include?(membership.account_id) ? @routes.account_rhythms_path(membership.account) : nil
        row.merge(rhythms: { count: count, url: url })
      end
    end

    # { membership public id => { chat:, telegram:, other: } } for the seats
    # with a run going in a conversation of the account they are a guest in;
    # seats with nothing running are absent.
    def sessions
      return {} if @memberships.empty?

      counts = AgentRuntimeInteraction.working
        .joins(:chat)
        .where(agent_id: @memberships.map(&:agent_id).uniq, chats: { account_id: @memberships.map(&:account_id).uniq })
        .group(:agent_id, "chats.account_id", :trigger_kind).count
      @memberships.each_with_object({}) do |membership, seats|
        counts.each do |(agent_id, account_id, trigger_kind), count|
          next unless agent_id == membership.agent_id && account_id == membership.account_id

          (seats[membership.to_param] ||= ResidentSessions.empty)[ResidentSessions.kind_for(trigger_kind)] += count
        end
      end
    end

    private

    def rhythm_counts
      return {} if @memberships.empty?

      RhythmAgent.joins(:rhythm)
        .where(agent_id: @memberships.map(&:agent_id).uniq, rhythms: { account_id: @memberships.map(&:account_id).uniq })
        .group("rhythms.account_id", :agent_id).count
    end

    def reachable_account_ids
      return Set.new unless @user
      return @memberships.map(&:account_id).to_set if @user.site_admin

      @user.confirmed_accounts.where(id: @memberships.map(&:account_id)).pluck(:id).to_set
    end

  end
end
