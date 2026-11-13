module Agents
  class VmMigration
    # Removes the house volumes a recovered rollback left behind (#426).
    #
    # This is the first code in the house that deletes any part of a
    # resident's home, so it is narrow on purpose:
    #
    # - It runs only when asked (release!), never on a schedule. Whether the
    #   house should ever do this by itself is Daniel's call (jaMMNj).
    # - It is admitted only for a rollback that is recovered with its
    #   recovery bound to its swap receipt (RollbackRelease.unadmitted_reason),
    #   whose resident is still on that swap's map, at that reservation, with
    #   no other attempt open and its placement the house's, and only once
    #   HOLD has passed since the recovery was verified.
    # - What it may remove is a closed list computed from the records, never
    #   from what Docker happens to hold: the map the swap replaced (from its
    #   receipt), and the rollback volumes of this resident's earlier,
    #   spent generations. Every name must be this resident's own name for
    #   its role (Resources#derived_volumes, or that plus "-rb<generation>"
    #   below this attempt's), and none may be on the map it runs on now.
    # - Before each removal Docker is asked: a rollback volume must carry this
    #   resident's rollback label for its generation, a namespaced instance's
    #   volume this checkout's label, and no container may use it. Docker's
    #   own `volume rm` (without -f) refuses a volume in use as well.
    # - Docker is reached only through the local-endpoint guard the rest of
    #   the house uses (DockerLocalGuard): a local instance refuses any Docker
    #   that is not a Unix socket before a single volume is inspected.
    # - Each removal leaves evidence that survives a crash: an intent row,
    #   attributed to whoever asked, is committed before `docker volume rm`,
    #   and the receipt that follows names that intent. If the process dies
    #   between the two, a later run that finds the volume gone records the
    #   receipt against the original intent and its requester. A name already
    #   gone is reported, not an error, so asking twice is safe.
    # - The resident's original (derived) set is always on the list too, so
    #   that after a second rollback, whose receipt names the first's -rb
    #   set, the originals are not stranded (Mira, #943).
    class HouseVolumeRelease

      class Refused < StandardError; end

      HOLD = 7.days
      ROLES = Agents::Resources::ROLES
      ROLLBACK_LABEL = RollbackPlan::LABEL
      CHECKOUT_LABEL = "house.souls.checkout".freeze

      Candidate = Data.define(:role, :name, :source, :generation)
      Outcome = Data.define(:name, :status, :detail)

      DOCKER = ->(*argv) { Agents::BoundedCommand.capture3(*argv, deadline: Agents::BoundedCommand.now + 30) }
      GUARD = -> { Agents::DockerLocalGuard.check!(deadline: Agents::BoundedCommand.now + 30) }

      INTENDED = "house_volume_release_intended".freeze
      RELEASED = "house_volume_released".freeze
      FOUND_ABSENT = "house_volume_found_absent".freeze
      STOPPED = "house_volume_release_stopped".freeze
      RM_UNANSWERED = "Docker did not answer the removal in time".freeze

      # Why this rollback's leftovers may not be removed now, or nil.
      def self.unadmitted_reason(rollback, now: Time.current)
        refusal = RollbackRelease.unadmitted_reason(rollback)
        return refusal if refusal

        agent = Agent.find(rollback.agent_id)
        return "The resident is no longer on this rollback's volumes" unless agent.volume_map == rollback.volume_map.to_h
        unless agent.volume_rollback_generation.to_i == rollback.generation
          return "A newer rollback has been reserved for this resident"
        end
        return "Another rollback of this resident is still open" if VmRollback.open.where(agent_id: agent.id).exists?

        placement = AgentPlacement.find(rollback.agent_placement_id)
        unless placement.backend == "local" && placement.state == "ready" &&
            placement.generation == rollback.source["placement_generation"].to_i + 1
          return "The resident's placement is not the one this rollback made the house's"
        end

        verified_at = begin
          Time.iso8601(rollback.recovery.to_h["verified_at"].to_s)
        rescue ArgumentError
          nil
        end
        return "The recovery has no verified time" unless verified_at
        if verified_at > now - HOLD
          return "The old volumes are kept until #{(verified_at + HOLD).utc.iso8601}, #{HOLD.inspect} after the recovery"
        end

        nil
      end

      def initialize(rollback, docker: DOCKER, guard: GUARD, instance: LocalInstance.current, now: -> { Time.current })
        @rollback = rollback
        @agent_id = rollback.agent_id
        @docker = docker
        @guard = guard
        @instance = instance
        @now = now
      end

      # The closed list, from the records alone. Raises Refused if a recorded
      # name is not this resident's own, rather than skipping it quietly.
      def candidates
        agent = Agent.find(@agent_id)
        resources = Agents::Resources.new(agent, instance: @instance)
        derived = resources.derived_volumes.transform_keys(&:to_s)
        live = @rollback.volume_map.to_h.values

        swap = AuditLog.where(action: "vm_rollback_swap", auditable_type: "Agent", auditable_id: agent.id)
          .where("data->>'generation' = ?", @rollback.generation.to_s).order(:id).first
        raise Refused, "The swap receipt for this rollback is missing" unless swap

        previous = swap.data["previous_map"] || derived
        list = ROLES.map(&:to_s).map do |role|
          name = previous.fetch(role) { raise Refused, "The swap receipt names no #{role} volume" }
          Candidate.new(role:, name:, source: "replaced_map", generation: generation_of(name, derived.fetch(role)))
        end
        ROLES.map(&:to_s).each do |role|
          list << Candidate.new(role:, name: derived.fetch(role), source: "original", generation: nil)
        end
        (1...@rollback.generation).each do |generation|
          ROLES.map(&:to_s).each do |role|
            list << Candidate.new(role:, name: "#{derived.fetch(role)}-rb#{generation}", source: "spent_generation", generation:)
          end
        end

        # Every recorded name is checked for its role before duplicates go,
        # so a malformed entry is refused, never hidden behind a good one.
        list.each { |candidate| check_own!(candidate, derived) }
        list.uniq(&:name).reject { |candidate| live.include?(candidate.name) }
      end

      # Removes the closed list, one volume at a time, each in two committed
      # steps under the resident's row lock: first the admission is rechecked
      # and an attributed intent committed; then the admission is rechecked
      # again, Docker is checked, the volume removed and its receipt (naming
      # the intent) committed. So a failure at volume N never rolls back the
      # receipt of a volume already gone, and a crash between `rm` and the
      # receipt still leaves the intent (Mira, #943). A Docker call that
      # fails or times out is reported as :unknown and the rest still run.
      # Returns one Outcome per name. Refused (nothing removed, nothing
      # written) if the Docker endpoint is not local or the release is not
      # admitted at the start; a later loss of admission stops each remaining
      # name before its `rm`.
      def release!(by:)
        # Inside an enclosing transaction each "committed" intent would only
        # be a savepoint, gone with the caller's rollback while the volume it
        # names may already be removed. So, like the swap, top level only.
        raise Refused, "The release must not run inside an open transaction" if Agent.connection.transaction_open?

        @guard.call
        agent = Agent.find(@agent_id)
        list = agent.with_lock do
          admit!
          candidates
        end

        list.map do |candidate|
          release_one(candidate, agent:, by:)
        rescue Agents::BoundedCommand::TimedOut
          Outcome.new(name: candidate.name, status: :unknown, detail: "Docker did not answer in time")
        end
      end

      protected

      # Why this release may not go on now, read afresh, or nil. Each kind of
      # release (after a rollback, after a move) answers it for its own basis.
      def current_refusal
        self.class.unadmitted_reason(@rollback.reload, now: @now.call)
      end

      # What names the basis in every intent, receipt and stop row.
      def subject_data
        { "rollback_id" => @rollback.id, "generation" => @rollback.generation }
      end

      # A "-rb<generation>" volume is this release's to remove only for a
      # generation that is spent.
      def spent_generation?(generation)
        generation < @rollback.generation
      end

      private

      def release_one(candidate, agent:, by:)
        intent = agent.with_lock do
          refusal = current_refusal
          next Outcome.new(name: candidate.name, status: :not_admitted, detail: refusal) if refusal
          if receipted?(candidate, agent)
            next Outcome.new(name: candidate.name, status: :absent, detail: "Already released")
          end

          AuditLog.create!(action: INTENDED, user: by, account: agent.account, auditable: agent,
            data: receipt_data(candidate))
        end
        return intent if intent.is_a?(Outcome)

        begin
          @guard.call
        rescue StandardError => error
          agent.with_lock { stop(intent, Outcome.new(name: candidate.name, status: :refused, detail: error.message.first(200)), agent:) }
          raise
        end

        agent.with_lock do
          refusal = current_refusal
          next stop(intent, Outcome.new(name: candidate.name, status: :not_admitted, detail: refusal), agent:) if refusal

          outcome = begin
            remove(candidate, agent:, by:, intent:)
          rescue Agents::BoundedCommand::TimedOut
            Outcome.new(name: candidate.name, status: :unknown, detail: "Docker did not answer in time, before any removal")
          end
          next outcome if %i[removed absent].include?(outcome.status) || outcome.detail == RM_UNANSWERED

          stop(intent, outcome, agent:)
        end
      end

      # Closes an intent whose volume was certainly not removed by it, so a
      # later absence is never attributed to a request that never reached
      # `rm`. An `rm` whose answer was lost leaves its intent open on purpose.
      def stop(intent, outcome, agent:)
        AuditLog.create!(action: STOPPED, user: intent.user, account: agent.account, auditable: agent,
          data: intent.data.merge("intent_id" => intent.id, "status" => outcome.status.to_s, "detail" => outcome.detail))
        outcome
      end

      def receipt_data(candidate)
        subject_data.merge("volume" => candidate.name, "role" => candidate.role, "source" => candidate.source,
          "volume_generation" => candidate.generation)
      end

      # Earlier intents for this name that no outcome has closed.
      def open_intents(candidate, agent:, except:)
        AuditLog.where(auditable: agent, action: INTENDED).where("data->>'volume' = ?", candidate.name)
          .where.not(id: except.id)
          .where.not(id: AuditLog.where(auditable: agent, action: STOPPED).select(Arel.sql("(data->>'intent_id')::bigint")))
          .order(:id)
      end

      def receipted?(candidate, agent)
        AuditLog.where(auditable: agent, action: [ RELEASED, FOUND_ABSENT ])
          .where("data->>'volume' = ?", candidate.name).exists?
      end

      def admit!
        refusal = current_refusal
        raise Refused, refusal if refusal
      end

      def generation_of(name, base)
        return nil if name == base

        suffix = name.delete_prefix(base)
        suffix.match?(Agents::Resources::ROLLBACK_SUFFIX) ? suffix.delete_prefix("-rb").to_i : nil
      end

      def check_own!(candidate, derived)
        base = derived.fetch(candidate.role)
        own = candidate.name == base ||
          (candidate.generation && spent_generation?(candidate.generation) && candidate.name == "#{base}-rb#{candidate.generation}")
        raise Refused, "#{candidate.name} is not this resident's #{candidate.role} volume" unless own
      end

      def remove(candidate, agent:, by:, intent:)
        out, err, status = @docker.call("docker", "volume", "inspect", "--format",
          "{{ index .Labels \"#{ROLLBACK_LABEL}\" }}|{{ index .Labels \"#{CHECKOUT_LABEL}\" }}", candidate.name)
        unless status.success?
          return absent(candidate, agent:, by:, intent:) if err.to_s.match?(/no such volume/i)

          return Outcome.new(name: candidate.name, status: :unknown, detail: "Could not inspect the volume")
        end

        # The volume is still here, so no earlier open intent removed it.
        open_intents(candidate, agent:, except: intent).each do |earlier|
          stop(earlier, Outcome.new(name: candidate.name, status: :unknown, detail: "The volume was still present at a later attempt"), agent:)
        end

        rollback_label, checkout_label = out.to_s.strip.split("|", 2).map(&:to_s)
        if candidate.generation && !rollback_label.start_with?("#{agent.uuid}/#{candidate.generation}/")
          return Outcome.new(name: candidate.name, status: :foreign, detail: "Not labelled as this resident's rollback #{candidate.generation}")
        end
        if @instance.namespace && checkout_label != @instance.fingerprint
          return Outcome.new(name: candidate.name, status: :foreign, detail: "Not labelled as this checkout's")
        end

        users, _err, status = @docker.call("docker", "ps", "-a", "-q", "--filter", "volume=#{candidate.name}")
        return Outcome.new(name: candidate.name, status: :unknown, detail: "Could not list its containers") unless status.success?
        return Outcome.new(name: candidate.name, status: :in_use, detail: "A container still uses it") if users.to_s.strip.present?

        begin
          _out, err, status = @docker.call("docker", "volume", "rm", candidate.name)
        rescue Agents::BoundedCommand::TimedOut
          return Outcome.new(name: candidate.name, status: :unknown, detail: RM_UNANSWERED)
        end
        return Outcome.new(name: candidate.name, status: :refused, detail: err.to_s.strip.first(200)) unless status.success?

        AuditLog.create!(action: RELEASED, user: by, account: agent.account, auditable: agent,
          data: receipt_data(candidate).merge("intent_id" => intent.id))
        Outcome.new(name: candidate.name, status: :removed, detail: nil)
      end

      # A name Docker no longer has. An intent stays open only while it may
      # have removed the volume: one that certainly did not (refused, in use,
      # not admitted, or followed by an attempt that found the volume still
      # there) is closed as stopped. If exactly one earlier intent is open, it
      # is the one whose `rm` Docker carried out before the process died or
      # its answer was lost, and the receipt is written now against it,
      # attributed to whoever asked for it and marked as reconciled. With no
      # open intent (a hand removal) or several the evidence cannot tell
      # apart, the absence is recorded as found absent, without a guess.
      def absent(candidate, agent:, by:, intent:)
        earlier = open_intents(candidate, agent:, except: intent).to_a
        if earlier.one?
          earlier = earlier.first
          AuditLog.create!(action: RELEASED, user: earlier.user, account: agent.account, auditable: agent,
            data: receipt_data(candidate).merge("intent_id" => earlier.id, "reconciled_by_intent_id" => intent.id,
                                                "reconciled" => true))
        else
          # No open intent (a hand removal), or several that the evidence
          # cannot tell apart: the absence is recorded without a guess.
          AuditLog.create!(action: FOUND_ABSENT, user: by, account: agent.account, auditable: agent,
            data: receipt_data(candidate).merge("intent_id" => intent.id, "open_intent_ids" => earlier.map(&:id)))
        end
        Outcome.new(name: candidate.name, status: :absent, detail: nil)
      end

    end
  end
end
