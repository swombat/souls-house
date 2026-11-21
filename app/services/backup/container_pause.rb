module Backup
  # A backup holds a resident still by pausing its container
  # (AgentRestic.paused). Nothing else in the house pauses a resident's
  # container, so one that stays paused has been left that way, and the
  # resident is frozen: runs sent to it are accepted and wait, and once its
  # health checks fail they fail at once. On 19 Nov 2026 Mira was left like
  # that from about 04:06 to 05:32Z, after the nightly backup, until someone
  # unpaused her by hand.
  #
  # What the house does about it, and what it doesn't (#1042, scoped with
  # Mira): a backup whose own unpause fails tries once more and checks; a
  # resident seen paused for a long time is reported (PausedResidentWatchJob);
  # a run refused while a resident is paused says "paused, cause
  # unconfirmed". Nothing unpauses a container this backup did not pause:
  # doing that safely needs a fence against backup work that is still
  # running, which is its own piece of work.
  module ContainerPause

    # Reported when a resident's container stays paused (or Docker can't
    # say) after a backup's unpause, or has been seen paused for a long time.
    class StillPaused < StandardError; end
    # Reported when a backup's first unpause failed and the second worked.
    class UnpauseRetried < StandardError; end
    # Reported when a resident is found paused and no backup claims that
    # pause (Backup::PauseClaim). Never a reason to unpause it.
    class UnclaimedPause < StandardError; end
    # Reported when a backup finds the resident paused under an earlier
    # backup's claim for the same container. Report only: a claim records
    # intent, not that the pause is the backup's.
    class ClaimedPause < StandardError; end

    DOCKER_TIMEOUT = 30 # seconds

    module_function

    # :running, :paused, :stopped or :unknown (no answer, or no container).
    def state(agent, container: agent.container_name)
      out, _, status = capture("docker", "inspect", "--format", "{{.State.Running}} {{.State.Paused}}", container)
      return :unknown unless status&.success?

      case out.to_s.strip
      when "true true" then :paused
      when "true false" then :running
      when /\Afalse / then :stopped
      else :unknown
      end
    rescue StandardError
      :unknown
    end

    # The second try after a backup's own unpause failed: unpause if still
    # paused, then look. :unpaused, :not_paused (the first one had worked),
    # :still_paused, or :unknown when Docker can't say, which is never taken
    # for unpaused (Mira, #1042). Reports every outcome but :not_paused.
    # Never raises.
    def retry_unpause!(agent, container: agent.container_name)
      case state(agent, container:)
      when :running, :stopped then return :not_paused
      when :unknown
        report(StillPaused, agent, "may still be paused: its backup's unpause failed and Docker couldn't say after")
        return :unknown
      end

      _, _, status = capture("docker", "unpause", container)
      after = state(agent, container:)
      if status&.success? && after == :running
        report(UnpauseRetried, agent, "stayed paused when its backup's unpause failed; a second unpause worked")
        :unpaused
      else
        report(StillPaused, agent, "is still paused: its backup's unpause failed twice")
        after == :unknown ? :unknown : :still_paused
      end
    rescue StandardError => error
      Rails.logger.error("[Backup::ContainerPause] unpausing resident #{agent&.id} failed: #{error.class}")
      :unknown
    end

    def report(klass, agent, what)
      message = "Resident #{agent.id} (#{agent.name})'s container #{what}"
      Rails.logger.warn("[Backup::ContainerPause] #{message}")
      Rails.error.report(klass.new(message), handled: true)
    end

    def capture(*args)
      Agents::BoundedCommand.capture3(*args, deadline: Agents::BoundedCommand.now + DOCKER_TIMEOUT)
    end

  end
end
