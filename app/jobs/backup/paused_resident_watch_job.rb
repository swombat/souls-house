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
  # the resident's account owner and the house's site admins. Until 21 Nov
  # 2026 it reached only the error tracker, which nobody reads. Each
  # recipient is tracked on its own: one failed send doesn't stop the
  # others, and it is tried again on the next tick while the pause holds.
  # No "running again" email: leaving the paused list doesn't show that a
  # resident is running (a stopped or removed container leaves it too).
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
        if since <= now - PAUSED_FOR
          unless entry["reported"]
            ContainerPause.report(ContainerPause::StillPaused, agent,
              "has been paused since at least #{since.utc.iso8601}. It was not unpaused automatically; " \
              "once no backup of it is running, `docker unpause #{agent.container_name}` frees it")
            entry = entry.merge("reported" => true)
          end
          entry = entry.merge("emailed" => email_frozen(agent, entry["since"], Array(entry["emailed"])))
        end
        still[agent.id.to_s] = entry
      end
      Rails.cache.write(CACHE_KEY, still)
    end

    private

    # The ids emailed so far this episode, with any newly sent. Each
    # recipient on its own: a failure is logged and left for the next tick.
    def email_frozen(agent, since, emailed)
      recipients = ([ agent.account.owner ] + site_admins).compact.uniq.reject { |user| emailed.include?(user.id) }
      recipients.each_with_object(emailed.dup) do |user, sent|
        sent << user.id if ResidentHealthMailer.resident_frozen(agent, since, user).deliver_later
      rescue StandardError => error
        Rails.logger.error("[Backup::PausedResidentWatchJob] emailing user #{user.id} about resident #{agent.id} failed: #{error.class}")
      end
    end

    # The same people User#site_admin answers true for: the flag on the
    # user, or a confirmed membership of an enabled site-admin account.
    def site_admins
      by_account = Membership.confirmed.joins(:account).merge(Account.enabled).where(accounts: { is_site_admin: true }).select(:user_id)
      User.where(is_site_admin: true).or(User.where(id: by_account)).to_a
    rescue StandardError => error
      Rails.logger.error("[Backup::PausedResidentWatchJob] listing site admins failed: #{error.class}")
      []
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
