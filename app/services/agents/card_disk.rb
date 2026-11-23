module Agents
  # The disk figure a resident's card shows, from whichever walker measures
  # it: storage_usage (the daily house-host walk) for a resident here,
  # home_storage (its runner's walk) for one on its own server. One shape:
  #   status       nil (not measured yet), "measured", "too_slow", "unavailable"
  #   bytes        the latest size any walk found, or nil
  #   measured_at  when that size was found
  #   attempted_at when the latest walk was tried
  #   reason       why an unavailable walk failed, in the house's words
  #   partial      true when the walk found only some of the volumes
  module CardDisk

    module_function

    def call(agent, remote: Agents::RemoteRuntime.remote?(agent))
      return remote(agent.home_storage.to_h) if remote

      local(agent.storage_usage.to_h)
    end

    def remote(storage)
      return {} if storage["status"].blank?

      storage.slice("status", "bytes", "measured_at", "attempted_at", "reason")
    end

    def local(usage)
      base = { "bytes" => usage["bytes"], "measured_at" => usage["measured_at"], "attempted_at" => usage["checked_at"] }
      case usage["status"]
      when "measured" then base.merge("status" => "measured")
      # Some of its volumes were missing: a size, but not the whole home's.
      when "partial" then base.merge("status" => "measured", "partial" => true)
      when "unavailable"
        if out_of_time?(usage)
          base.merge("status" => "too_slow")
        else
          base.merge("status" => "unavailable", "reason" => "failed")
        end
      else {}
      end.compact
    end

    # The daily walker's own busybox timeout kills du, which then reads as
    # du_failed, not timeout ("timeout" is only the outer Ruby limit). A
    # du_failed walk that lasted its whole budget ran out of time (Mira, #1111).
    def out_of_time?(usage)
      return true if usage["failure"] == "timeout"

      usage["failure"] == "du_failed" && usage["attempt_seconds"].to_f >= Agents::StorageUsage::DU_SECONDS
    end

  end
end
