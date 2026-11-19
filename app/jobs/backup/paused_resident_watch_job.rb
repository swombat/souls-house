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
          entry = entry.merge("reported" => true)
        end
        still[agent.id.to_s] = entry
      end
      Rails.cache.write(CACHE_KEY, still)
    end

    private

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
