module Agents
  class VmMigration
    # Checkpoint 3 of #426 3C: bringing a moved resident back to the house.
    #
    # What it protects: the house home the resident lived in before the move.
    # A rollback never writes into a live volume. Every one of the five
    # volumes (identity, chaos, repo, work, state) is restored from the
    # resident's own repository into a FRESH volume named for this rollback;
    # only when all five are restored and verified is the resident pointed at
    # them, by one commit of agents.volume_map (RollbackSwap). The old volumes
    # stay untouched until a later, separate release, so a rollback that fails
    # at any step before that commit leaves the house exactly as it was.
    #
    # Fresh names are the DERIVED name for each role plus "-rb<generation>",
    # whatever map the resident runs on now, so Resources#volumes can always
    # tell a rollback volume of this resident from anyone else's.
    #
    # The fence. A generation comes only from reserve!, which raises the
    # agent's volume_rollback_generation under its row lock: two rollbacks
    # never share a generation, and a failed attempt's generation is never
    # handed out again. allocate! then refuses any fresh name that already
    # exists, creates each volume with a label naming this resident,
    # generation and a per-attempt nonce, and reads the label back; a volume
    # that some other process created in between carries another label (or
    # none, since `docker volume create` on an existing name succeeds and
    # keeps the old one) and is refused.
    class RollbackPlan
      class Unsafe < StandardError; end

      ROLES = Agents::Resources::ROLES
      LABEL = "house.souls.rollback".freeze

      Target = Data.define(:role, :live, :fresh)

      # The next generation for this resident, reserved for the caller alone.
      def self.reserve!(agent)
        agent.with_lock do
          generation = agent.volume_rollback_generation.to_i + 1
          agent.update_columns(volume_rollback_generation: generation)
          generation
        end
      end

      def initialize(agent, generation:, resources: Resources.new(agent))
        raise ArgumentError, "generation must be a positive integer" unless generation.is_a?(Integer) && generation.positive?

        @agent = agent
        @generation = generation
        @resources = resources
        # The map this plan was computed from, captured once (Mira, #838
        # review 6758543392): the swap commits only while the agent is still
        # on exactly this map, so an old plan can never replace a newer
        # rollback's map, however freshly the agent was reloaded.
        @source_map = agent.respond_to?(:volume_map) ? agent.volume_map.deep_dup : nil
      end

      attr_reader :generation, :source_map

      # One target per role, in ROLES order. Raises Unsafe if the live map is
      # not exactly the five roles, names one volume twice, or if any fresh
      # name would be a live or derived name (of any role). Computed once: a
      # plan is fixed when it is first read, so after a swap the plan still
      # names what it restored into (RollbackSwap re-checks the agent's map).
      def targets
        @targets ||= compute_targets
      end

      def compute_targets
        live = @resources.volumes
        base = @resources.derived_volumes
        [ live, base ].each do |map|
          unless map.keys.sort == ROLES.sort
            raise Unsafe, "Rollback covers #{ROLES.join(', ')}; resources name #{map.keys.sort.join(', ')}"
          end
        end
        raise Unsafe, "The live volume map names one volume for two roles" unless live.values.uniq.size == ROLES.size

        planned = ROLES.map { |role| Target.new(role:, live: live.fetch(role), fresh: "#{base.fetch(role)}-rb#{generation}") }
        clash = planned.map(&:fresh) & (live.values | base.values)
        raise Unsafe, "Refusing to restore into a live volume: #{clash.join(', ')}" if clash.any?

        planned
      end

      private :compute_targets

      # The map a successful swap commits: role => fresh name.
      def fresh_map
        targets.to_h { |target| [ target.role.to_s, target.fresh ] }
      end

      # Refuses a plan whose fresh volumes already exist: a leftover from an
      # earlier attempt is never reused or overwritten.
      # exists: ->(name) -> boolean (a Docker volume inspect, injected).
      def check_fresh_absent!(exists:)
        present = targets.map(&:fresh).select { |name| exists.call(name) }
        raise Unsafe, "Rollback volumes already exist: #{present.join(', ')}" if present.any?

        true
      end

      def label_value(nonce)
        raise ArgumentError, "nonce must be 16+ hex characters" unless nonce.to_s.match?(/\A[0-9a-f]{16,64}\z/)

        "#{@agent.uuid}/#{generation}/#{nonce}"
      end

      # Creates the five fresh volumes, fenced as described above. docker is
      # a capture3-shaped callable: docker.call(*argv) -> [stdout, stderr, status].
      # Returns the targets. Creates nothing if any fresh name exists already.
      def allocate!(docker:, nonce: SecureRandom.hex(16))
        label = label_value(nonce)
        exists = lambda do |name|
          _out, err, status = docker.call("docker", "volume", "inspect", name)
          next true if status.success?
          next false if err.to_s.match?(/no such volume/i)

          raise Unsafe, "Cannot tell whether rollback volume #{name} exists"
        end
        check_fresh_absent!(exists:)

        targets.each do |target|
          _out, _err, status = docker.call("docker", "volume", "create", *@resources.labels, "--label", "#{LABEL}=#{label}", target.fresh)
          raise Unsafe, "Could not create rollback volume #{target.fresh}" unless status.success?

          out, _err, status = docker.call("docker", "volume", "inspect", "--format", "{{ index .Labels \"#{LABEL}\" }}", target.fresh)
          unless status.success? && out.to_s.strip == label
            raise Unsafe, "Rollback volume #{target.fresh} is not this attempt's: refusing to restore into it"
          end
        end
      end
    end
  end
end
