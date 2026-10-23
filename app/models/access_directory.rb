# Who can read the conversations of an account, and why: the answer to
# `souls who` (GET /api/v1/who) and, for one conversation,
# `souls who <conversation>` (GET /api/v1/conversations/:id/who).
#
# It reports the rules the house already enforces; it grants nothing:
#   - a person with a confirmed membership reads every conversation in the
#     account (the API's human_chats, the web's current_account.chats). That
#     includes "external" logins an agent drives, which are memberships too;
#   - a resident, at home or as a guest, reads only the conversations it has
#     a seat in (agent.chats);
#   - a site admin can open any conversation in any account (account
#     switching and messages#set_message), member or not.
# Telegram conversations are a separate thing and are not covered.
#
# Asked for by Claude and Daniel in nJdMBY so that cross-house sight is
# findable without being announced all the time. Names only: no emails.
class AccessDirectory

  READS_ALL = "every conversation in this account".freeze
  READS_SEATED = "only the conversations it has a seat in".freeze
  READS_ANY = "any conversation in any account, through the site admin view".freeze
  NOT_COVERED = "Telegram conversations are separate from house conversations and are not covered here.".freeze

  def initialize(account)
    @account = account
  end

  def as_json(*)
    {
      account: { id: @account.to_param, name: @account.name },
      people: memberships.map { |membership| person_json(membership) },
      residents: residents.map { |agent| resident_json(agent) },
      site_admins: outside_site_admins.map { |user| { name: name_of(user), reads: READS_ANY } },
      not_covered: NOT_COVERED
    }
  end

  # Everyone who can read this one conversation, each with the reason.
  def conversation_json(chat)
    readers = memberships.map do |membership|
      { name: name_of(membership.user), kind: "person", role: membership.role,
        why: "member of #{@account.name} (#{membership.role})", site_admin: site_admin_ids.include?(membership.user_id) }
    end
    readers += outside_site_admins.map do |user|
      { name: name_of(user), kind: "site_admin", why: "site admin" }
    end
    readers += chat.chat_agents.includes(:agent).sort_by { |seat| seat.agent.name.to_s.downcase }.map do |seat|
      guest = seat.agent.account_id != @account.id
      { id: seat.agent.to_param, name: seat.agent.name, kind: guest ? "guest_resident" : "resident",
        why: guest ? "guest seat in this conversation" : "seat in this conversation",
        closed_for_initiation: seat.closed_for_initiation_at.present? }
    end

    { conversation: { id: chat.to_param, title: chat.title }, account: { id: @account.to_param, name: @account.name },
      readers: readers, not_covered: NOT_COVERED }
  end

  private

  def memberships
    @memberships ||= @account.memberships.confirmed.includes(user: :profile).sort_by { |membership| name_of(membership.user).downcase }
  end

  def residents
    home = @account.agents.active.to_a
    guests = @account.guest_agents.active.to_a
    (home + guests).uniq.sort_by { |agent| agent.name.to_s.downcase }
  end

  def resident_json(agent)
    guest = agent.account_id != @account.id
    { id: agent.to_param, name: agent.name, kind: guest ? "guest_resident" : "resident",
      reads: READS_SEATED, seats: seat_counts.fetch(agent.id, 0), paused: agent.paused? }
  end

  def person_json(membership)
    { name: name_of(membership.user), kind: "person", role: membership.role, reads: READS_ALL,
      site_admin: site_admin_ids.include?(membership.user_id) }
  end

  def seat_counts
    @seat_counts ||= ChatAgent.joins(:chat).merge(Chat.kept).where(chats: { account_id: @account.id }).group(:agent_id).count
  end

  def site_admin_ids
    @site_admin_ids ||= begin
      flagged_accounts = Account.enabled.where(is_site_admin: true).select(:id)
      via_account = Membership.confirmed.where(account_id: flagged_accounts).select(:user_id)
      User.where(is_site_admin: true).or(User.where(id: via_account)).pluck(:id).to_set
    end
  end

  # Site admins who are not members here: they can still open its rooms.
  def outside_site_admins
    member_ids = memberships.map(&:user_id)
    User.where(id: site_admin_ids.to_a - member_ids).includes(:profile).to_a.sort_by { |user| name_of(user).downcase }
  end

  def name_of(user)
    user.full_name.presence || "(no name set)"
  end

end
