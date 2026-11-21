module Backup
  # Scheduled (config/recurring.yml). Reports a resident on this host whose
  # container has been seen paused for PAUSED_FOR or longer, once per
  # episode. A backup pauses its resident for minutes; one left paused (its
  # worker killed by a deploy, say) stayed that way until someone noticed.
  #
  # It reports and does not unpause (#1042, scoped with Mira): the house
  # can't yet tell a backup that was killed from one whose Docker work is
  # still running, and unpausing under the second would resume a resident in
  # the middle of its checkpoint. That recovery is its own piece of work.
  #
  # The report also goes by email (ResidentHealthMailer#resident_frozen) to
  # the resident's account admins and the house's site admins, and a second
  # email goes to the same people once the resident is seen running again.
  # Until 21 Nov 2026 it reached only the error tracker, which nobody reads.
  class PausedResidentWatchJob < ApplicationJob

    queue_as :default

    PAUSED_FOR = 30.minutes
    CACHE_KEY = "backup/paused_resident_watch"

    def perform(now: Time.current)
      return unless Agents::Config.backups_enabled?
      return if LocalInstance.current.namespace

      names = paused_container_names
      return if names.nil?

      seen = Rails.cache.read(CACHE_KEY) || {}
      still = {}
      Agent.externally_hosted.where(container_name: names).find_each do |agent|
        next if Agents::RemoteRuntime.remote?(agent)

        entry = seen[agent.id.to_s] || { "since" => now.iso8601, "reported" => false }
        since = Time.zone.parse(entry["since"])
        if !entry["reported"] && since <= now - PAUSED_FOR
          ContainerPause.report(ContainerPause::StillPaused, agent,
            "has been paused since at least #{since.utc.iso8601}. It was not unpaused automatically; " \
            "once no backup of it is running, `docker unpause #{agent.container_name}` frees it")
          entry = entry.merge("reported" => true, "emailed" => email_frozen(agent, entry["since"]))
        end
        still[agent.id.to_s] = entry
      end
      email_unfrozen(seen.except(*still.keys))
      Rails.cache.write(CACHE_KEY, still)
    end

    private

    # Ids of the users emailed. Account admins hear that the cause is the
    # house's; site admins get the same email with the recovery steps.
    def email_frozen(agent, since)
      operators = site_admins
      admins = agent.account.memberships.confirmed.admins.includes(:user).filter_map(&:user)
      (admins + operators).uniq.map do |user|
        ResidentHealthMailer.resident_frozen(agent, since, user, operator: operators.include?(user)).deliver_later
        user.id
      end
    rescue StandardError => error
      Rails.logger.error("[Backup::PausedResidentWatchJob] emailing about resident #{agent.id} failed: #{error.class}")
      []
    end

    # Residents reported frozen that Docker now lists as not paused.
    def email_unfrozen(gone)
      gone.each do |agent_id, entry|
        next if Array(entry["emailed"]).empty?
        next unless (agent = Agent.find_by(id: agent_id))

        User.where(id: entry["emailed"]).find_each do |user|
          ResidentHealthMailer.resident_unfrozen(agent, entry["since"], user).deliver_later
        end
      end
    rescue StandardError => error
      Rails.logger.error("[Backup::PausedResidentWatchJob] emailing a recovery failed: #{error.class}")
    end

    # The same people User#site_admin answers true for: the flag on the
    # user, or a confirmed membership of an enabled site-admin account.
    def site_admins
      by_account = Membership.confirmed.joins(:account).merge(Account.enabled).where(accounts: { is_site_admin: true }).select(:user_id)
      User.where(is_site_admin: true).or(User.where(id: by_account)).to_a
    end

    # nil when Docker didn't answer: the record of what was seen is kept.
    def paused_container_names
      out, _, status = ContainerPause.capture("docker", "ps", "--filter", "status=paused", "--format", "{{.Names}}")
      return nil unless status&.success?

      out.to_s.split("\n").map(&:strip).reject(&:blank?)
    rescue StandardError => error
      Rails.logger.error("[Backup::PausedResidentWatchJob] listing paused containers failed: #{error.class}")
      nil
    end

  end
end
