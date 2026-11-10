module Agents
  class VmMigration
    # The house half of a rollback (#426 3C checkpoint 3): the resident's
    # final snapshot from its server, five volumes in one restic snapshot,
    # restored into five FRESH house volumes, each verified, then one swap.
    #
    # The order is the safety (Mira, #838 reviews):
    #   1. Top level only. Nothing here runs inside an open transaction.
    #   2. The generation is reserved (RollbackPlan.reserve!) by the caller
    #      BEFORE any external IO, and the server's final snapshot is taken
    #      for that generation. This class refuses any generation but the
    #      latest reserved one before any IO, and RollbackSwap checks it again
    #      under the commit's lock, so an attempt superseded during its
    #      restore cannot reach the swap either.
    #   3. The snapshot is read back: its id, its tags (this resident, this
    #      generation, rollback=v1), its host and exactly the five paths.
    #   4. The fresh volumes are allocated with RollbackPlan#allocate!
    #      (refuses existing names, labels them per attempt, reads back).
    #   5. Each role is restored by id with `restore --verify` (RollbackRestore),
    #      through a READ-ONLY carry adapter with --no-lock: a rollback never
    #      writes to the resident's repository, not even a lock.
    #   6. Each fresh volume is shaped with the same carry_shape.sh the server
    #      ran in its stopped window; a role is verified only when its restore
    #      exited 0 AND its shape matches the server's.
    #   7. RollbackSwap commits the map only if all five are verified.
    #
    # A failure at any step before the swap leaves the resident on its live
    # volumes and its placement as it was; the fresh volumes are leftovers for
    # the separate release and are never reused (the generation is spent).
    class RollbackHome
      class Failed < StandardError; end

      IMAGE = CarrySnapshot::IMAGE
      ROLES = RollbackPlan::ROLES
      PATHS = ROLES.map { |role| RollbackRestore.path(role) }.freeze
      HOSTNAME = "souls-house-rollback".freeze
      SECONDS = 3600
      CLEANUP_SECONDS = 15

      # What the server's final snapshot reported: the restic id, and per
      # role the carry_shape.sh result ({ "entries" => n, "shape" => hex }).
      Snapshot = Data.define(:snapshot_id, :shapes)

      Result = Data.define(:generation, :verified, :shapes, :swap) do
        def ok? = swap&.ok? || false
      end

      def self.tags(agent, generation)
        [ "agent=#{agent.uuid}", "generation=#{Integer(generation)}", "rollback=v1" ]
      end

      def initialize(agent, generation:, snapshot:, command: Agents::BoundedCommand, adapter: CarryAdapter,
                     mountinfo: -> { File.read("/proc/self/mountinfo") }, resources: Agents::Resources.new(agent),
                     nonce: SecureRandom.hex(16))
        @agent = agent
        @generation = generation
        @snapshot = snapshot
        @command = command
        @adapter = adapter
        @mountinfo = mountinfo
        @resources = resources
        @nonce = nonce
      end

      # in_commit and start are RollbackSwap's: the placement switch inside
      # the commit, the container recreate after it.
      def call(in_commit: ->(_agent) {}, start: ->(_agent) {}, deadline: Agents::BoundedCommand.now + SECONDS)
        raise Failed, "A rollback must not run inside an open transaction" if Agent.connection.transaction_open?

        @deadline = deadline
        check_generation!
        shapes = expected_shapes!
        plan = RollbackPlan.new(@agent, generation: @generation, resources: @resources)
        container = own_container!
        verified = ROLES.to_h { |role| [ role, false ] }
        restored = {}

        @adapter.open(@agent, deadline: work_deadline, read_only: true) do |adapter|
          probe!(container, adapter)
          env = { "RESTIC_PASSWORD" => @agent.restic_password.to_s, "RESTIC_REPOSITORY" => adapter.repository_url }
          raise Failed, "The resident has no repository password" if env["RESTIC_PASSWORD"].empty?

          verify_snapshot!(container, env)
          # Only once the snapshot is proven this resident's and this
          # generation's are any volumes created.
          plan.allocate!(docker: ->(*argv) { @command.capture3(*argv, deadline: work_deadline) }, nonce: @nonce)
          plan.targets.each do |target|
            ok = restic!(container, env, *RollbackRestore.args(@snapshot.snapshot_id, target.role),
              mounts: [ "--mount", "type=volume,src=#{target.fresh},dst=#{RollbackRestore.path(target.role)}" ])
            raise Failed, "restic restore of the #{target.role} home failed" unless ok

            restored[target.role] = shape!(target.fresh)
            verified[target.role] = restored[target.role] == shapes.fetch(target.role)
          end
        end
        unverified = verified.reject { |_role, ok| ok }.keys
        raise Failed, "Restored homes do not match the server's: #{unverified.join(', ')}" if unverified.any?

        evidence = { "snapshot_id" => @snapshot.snapshot_id, "verified" => verified.transform_keys(&:to_s),
                     "shapes" => restored.transform_keys(&:to_s) }
        swap = RollbackSwap.new(@agent, plan:, verified:, in_commit:, start:, evidence:).call
        Result.new(generation: @generation, verified:, shapes: restored, swap:)
      rescue Agents::BoundedCommand::TimedOut
        raise Failed, "The rollback ran out of time"
      rescue RollbackPlan::Unsafe => error
        raise Failed, error.message
      end

      private

      def work_deadline = @deadline - CLEANUP_SECONDS

      def check_generation!
        unless @generation.is_a?(Integer) && @generation.positive? && @generation == Agent.uncached { Agent.where(id: @agent.id).pick(:volume_rollback_generation) }
          raise Failed, "Rollback generation #{@generation.inspect} is not this resident's latest reservation"
        end
      end

      def expected_shapes!
        id = @snapshot.snapshot_id.to_s
        raise Failed, "The server's final snapshot id is not a restic id" unless RollbackRestore::SNAPSHOT.match?(id)

        shapes = @snapshot.shapes
        raise Failed, "The server's final snapshot does not cover all five homes" unless shapes.is_a?(Hash) && shapes.keys.map(&:to_s).sort == ROLES.map(&:to_s).sort

        ROLES.to_h do |role|
          shape = shapes[role.to_s] || shapes[role]
          valid = shape.is_a?(Hash) && shape["entries"].is_a?(Integer) && !shape["entries"].negative? && CarrySnapshot::HASH.match?(shape["shape"].to_s)
          raise Failed, "The server's shape of the #{role} home is malformed" unless valid

          [ role, { "entries" => shape["entries"], "shape" => shape["shape"] } ]
        end
      end

      def own_container!
        ids = @mountinfo.call.scan(%r{/containers/([0-9a-f]{64})/}).flatten.uniq
        raise Failed, CarrySnapshot::NOT_IN_CONTAINER unless ids.one?

        out, _, status = @command.capture3("docker", "container", "inspect", "--format", "{{.Id}} {{.State.Running}}", ids.first,
          deadline: work_deadline)
        raise Failed, CarrySnapshot::NOT_IN_CONTAINER unless status.success? && out.strip == "#{ids.first} true"

        ids.first
      end

      def probe!(container, adapter)
        out = tool!([ "--network", "container:#{container}", "--entrypoint", "wget", IMAGE, "-q", "-T", "5", "-O", "-", adapter.probe_url ])
        raise Failed, "The rollback tool could not reach the house's carry adapter from this container" unless out == adapter.probe_answer
      end

      def verify_snapshot!(container, env)
        out = restic!(container, env, "snapshots", "--json", @snapshot.snapshot_id) || raise(Failed, "The final snapshot could not be read back")
        snapshots = JSON.parse(out)
        snapshot = snapshots.is_a?(Array) && snapshots.one? && snapshots.first
        unless snapshot.is_a?(Hash) && snapshot["id"] == @snapshot.snapshot_id &&
               snapshot["tags"].to_a.sort == self.class.tags(@agent, @generation).sort &&
               snapshot["paths"].to_a.sort == PATHS.sort && snapshot["hostname"] == HOSTNAME
          raise Failed, "The final snapshot is not of this resident and rollback generation"
        end
      rescue JSON::ParserError
        raise Failed, "The final snapshot could not be read back"
      end

      def shape!(volume)
        out = tool!([ "--network", "none", "--mount", "type=volume,src=#{volume},dst=/v,readonly", "--entrypoint", "sh", IMAGE,
                      "-c", File.read(CarrySnapshot::SHAPE_SCRIPT), "carry-shape", "/v" ]) || raise(Failed, "A restored home could not be measured")
        CarrySnapshot.parse_shape(out)
      rescue CarrySnapshot::Failed => error
        raise Failed, error.message
      end

      # stdout on success, nil on a non-zero exit. Always --no-lock: the
      # adapter is read-only and a rollback never writes to the repository.
      def restic!(container, env, *args, mounts: [])
        tool!([ "--network", "container:#{container}", "-e", "RESTIC_PASSWORD", "-e", "RESTIC_REPOSITORY",
                *mounts, IMAGE, "--no-cache", "--no-lock", "-o", "rest.connections=1", *args ], env:)
      end

      def tool!(args, env: {})
        name = "souls-house-rollback-#{SecureRandom.hex(12)}"
        argv = [ "docker", "run", "--rm", "--name", name, *@resources.labels, "--label", "house.souls.purpose=resident-rollback",
                 "--read-only", "--cap-drop", "ALL", "--cap-add", "CHOWN", "--cap-add", "FOWNER", "--cap-add", "DAC_OVERRIDE",
                 "--security-opt", "no-new-privileges", "--pids-limit", "64",
                 "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=256m", *args ]
        begin
          out, _, status = @command.capture3(env, *argv, deadline: work_deadline)
          status.success? ? out : nil
        ensure
          remove!(name)
        end
      end

      def remove!(name)
        _, err, status = @command.capture3("docker", "rm", "-f", name, deadline: Agents::BoundedCommand.now + CLEANUP_SECONDS)
        raise Failed, "A rollback tool could not be removed" unless status.success? || err.match?(/No such container|already in progress/i)
      end
    end
  end
end
