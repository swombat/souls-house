module Agents
  class VmMigration
    # The house half of a carry (#426 slice 3C, checkpoint 2): one restic
    # snapshot of the stopped resident's house `chaos` and `state` volumes,
    # written into its own VM repository, and the shape digest of each, taken
    # in the same stopped window. restore_carry on the server restores that
    # snapshot by id and must reproduce both digests before the resident may
    # start there.
    #
    # What it protects, and from whom: the resident's continuity, from a move
    # that starts it with an empty or partial home. Nothing about the files
    # leaves the volumes except restic's encrypted objects (through
    # CarryAdapter, so through VmRepository's budget, lock and no-overwrite
    # rules) and, per volume, an entry count and a digest. Volumes are
    # mounted read-only; the house home is not changed.
    #
    # The binding. A restic snapshot id is the hash of the snapshot object,
    # tags and paths included, and restic checks that hash when it loads one.
    # So once the snapshot read back here carries exactly this resident's
    # uuid, generation and runtime image, a restore pinned to its id gets
    # exactly that snapshot.
    #
    # Topology. restic runs in a container joined to the network namespace
    # of the container this process runs in (web, jobs, or a one-off exec of
    # the house image), resolved and inspected, never assumed; a probe proves
    # the tool can reach the adapter before the repository is touched.
    # Secrets (the repository password, the adapter's credential) go to
    # docker through its environment only, never its argv, and no tool's
    # output is put in an error.
    class CarrySnapshot

      # The VM runner's pinned image (host-runner/backup_proxy.py), so the
      # shape script runs on the same busybox on both sides.
      IMAGE = "restic/restic@sha256:39d9072fb5651c80d75c7a811612eb60b4c06b32ffe87c2e9f3c7222e1797e76".freeze
      ROLES = %w[chaos state].freeze
      PATHS = ROLES.map { |role| "/carry/#{role}" }.freeze
      HOSTNAME = "souls-house-carry".freeze
      SECONDS = 3600
      CLEANUP_SECONDS = 15
      SHAPE_SCRIPT = Rails.root.join("host-runner/carry_shape.sh")
      SHAPE = /\Aentries (0|[1-9][0-9]{0,9})\nshape ([0-9a-f]{64})\n?\z/
      HASH = /\A[0-9a-f]{64}\z/
      MISSING_REPOSITORY = 10 # restic's exit code for "repository does not exist"

      class Failed < StandardError; end

      Result = Data.define(:snapshot_id, :shapes, :tags)

      NOT_IN_CONTAINER = "The carry snapshot can only be taken from inside a house container (web, jobs or a one-off exec " \
                         "of the house image): this process's own container could not be identified.".freeze

      def initialize(agent, generation:, command: Agents::BoundedCommand, adapter: CarryAdapter,
                     mountinfo: -> { File.read("/proc/self/mountinfo") }, resources: Agents::Resources.new(agent))
        @agent = agent
        @generation = Integer(generation)
        @command = command
        @adapter = adapter
        @mountinfo = mountinfo
        @resources = resources
      end

      def tags
        image = @agent.container_image.to_s
        raise Failed, "The resident's runtime image can't be recorded on its carry" unless image.match?(/\A[A-Za-z0-9._\/:@-]{1,255}\z/)

        [ "agent=#{@agent.uuid}", "carry=v1", "generation=#{@generation}", "runtime=#{image}" ]
      end

      def call(deadline: Agents::BoundedCommand.now + SECONDS)
        @deadline = deadline
        expected_tags = tags
        container = own_container!
        shapes = ROLES.to_h { |role| [ role, shape!(role) ] }
        snapshot_id = nil
        @adapter.open(@agent, deadline: work_deadline) do |adapter|
          probe!(container, adapter)
          env = { "RESTIC_PASSWORD" => @agent.restic_password.to_s, "RESTIC_REPOSITORY" => adapter.repository_url }
          raise Failed, "The resident has no repository password" if env["RESTIC_PASSWORD"].empty?

          ensure_repository!(container, env)
          snapshot_id = backup!(container, env, expected_tags)
          verify_snapshot!(container, env, snapshot_id, expected_tags)
          restic!(container, env, "check") || raise(Failed, "restic check failed on the carry snapshot")
        end
        Result.new(snapshot_id:, shapes:, tags: expected_tags)
      rescue Agents::BoundedCommand::TimedOut
        raise Failed, "The carry snapshot ran out of time"
      end

      # The 64-hex id of the container this process runs in, from its
      # /etc/hostname bind mount, confirmed by docker: same id, running.
      def own_container!
        ids = @mountinfo.call.scan(%r{/containers/([0-9a-f]{64})/}).flatten.uniq
        raise Failed, NOT_IN_CONTAINER unless ids.one?

        out, _, status = @command.capture3("docker", "container", "inspect", "--format", "{{.Id}} {{.State.Running}}", ids.first,
          deadline: work_deadline)
        raise Failed, NOT_IN_CONTAINER unless status.success? && out.strip == "#{ids.first} true"

        ids.first
      end

      def self.parse_shape(text)
        match = SHAPE.match(text.to_s)
        raise Failed, "The resident's home could not be measured" unless match

        { "entries" => Integer(match[1], 10), "shape" => match[2] }
      end

      private

      def work_deadline = @deadline - CLEANUP_SECONDS

      def shape!(role)
        out = tool!([ "--network", "none", "--mount", mount(role, "/v"), "--entrypoint", "sh", IMAGE,
                      "-c", File.read(SHAPE_SCRIPT), "carry-shape", "/v" ]) || raise(Failed, "The resident's #{role} home could not be measured")
        self.class.parse_shape(out)
      end

      def probe!(container, adapter)
        out = tool!([ "--network", "container:#{container}", "--entrypoint", "wget", IMAGE, "-q", "-T", "5", "-O", "-", adapter.probe_url ])
        raise Failed, "The carry tool could not reach the house's carry adapter from this container" unless out == adapter.probe_answer
      end

      def ensure_repository!(container, env)
        return if restic!(container, env, "cat", "config")
        raise Failed, "The resident's repository could not be read" unless @last_exit == MISSING_REPOSITORY

        restic!(container, env, "init") || raise(Failed, "The resident's repository could not be created")
      end

      def backup!(container, env, expected_tags)
        mounts = ROLES.flat_map { |role| [ "--mount", mount(role, "/carry/#{role}") ] }
        out = restic!(container, env, "backup", "--json", "--host", HOSTNAME, *expected_tags.flat_map { |tag| [ "--tag", tag ] },
          *PATHS, mounts:) || raise(Failed, "restic backup of the resident's home failed")
        summaries = out.each_line.filter_map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end.select { |message| message.is_a?(Hash) && message["message_type"] == "summary" }
        id = summaries.one? && summaries.first["snapshot_id"].to_s
        raise Failed, "restic backup did not report one snapshot" unless id && HASH.match?(id)

        id
      end

      def verify_snapshot!(container, env, snapshot_id, expected_tags)
        out = restic!(container, env, "snapshots", "--json", snapshot_id) || raise(Failed, "The carry snapshot could not be read back")
        snapshots = JSON.parse(out)
        snapshot = snapshots.is_a?(Array) && snapshots.one? && snapshots.first
        unless snapshot.is_a?(Hash) && snapshot["id"] == snapshot_id && snapshot["tags"].to_a.sort == expected_tags.sort &&
               snapshot["paths"].to_a.sort == PATHS && snapshot["hostname"] == HOSTNAME
          raise Failed, "The carry snapshot is not of this resident, generation and runtime"
        end
      rescue JSON::ParserError
        raise Failed, "The carry snapshot could not be read back"
      end

      def mount(role, target)
        @resources.verify_existing!(deadline: work_deadline)
        "type=volume,src=#{@resources.volumes.fetch(role.to_sym)},dst=#{target},readonly"
      end

      # stdout on success, nil on a non-zero exit (kept in @last_exit).
      def restic!(container, env, *args, mounts: [])
        tool!([ "--network", "container:#{container}", "--cap-add", "DAC_READ_SEARCH", "-e", "RESTIC_PASSWORD", "-e", "RESTIC_REPOSITORY",
                *mounts, IMAGE, "--no-cache", "-o", "rest.connections=1", *args ], env:)
      end

      def tool!(args, env: {})
        name = "souls-house-carry-#{SecureRandom.hex(12)}"
        argv = [ "docker", "run", "--rm", "--name", name, *@resources.labels, "--label", "house.souls.purpose=resident-carry",
                 "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", "64",
                 "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=256m", *args ]
        begin
          out, _, status = @command.capture3(env, *argv, deadline: work_deadline)
          @last_exit = status.exitstatus
          status.success? ? out : nil
        ensure
          remove!(name)
        end
      end

      # Killing the docker client does not stop its container.
      def remove!(name)
        _, err, status = @command.capture3("docker", "rm", "-f", name, deadline: Agents::BoundedCommand.now + CLEANUP_SECONDS)
        raise Failed, "A carry tool could not be removed" unless status.success? || err.match?(/No such container|already in progress/i)
      end

    end
  end
end
