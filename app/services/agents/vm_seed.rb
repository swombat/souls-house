module Agents
  # The house side of seed_home (#246 slice 3): a new VM resident's first home.
  #
  # The archive is the same AgentIdentityExporter tarball a local resident is
  # seeded from. It is built once per placement and stored with its digest, so
  # every later seed_home names the same bytes: a runner that already unpacked
  # them answers "done", and one holding anything else refuses. The runner
  # fetches the archive by digest (RunnerEnrollment#authorize_seed!).
  #
  # Imported homes are not seeded here yet: their reviewed home has to reach
  # the VM by a path of its own.
  class VmSeed

    # Matches SEED_MAX_BYTES in host-runner/souls_house_runner.py.
    MAX_BYTES = 64.megabytes
    LIVE = %w[queued delivered done].freeze

    class Unavailable < StandardError; end

    Status = Data.define(:state, :error, :attempts) do
      def done? = state == :done
      def pending? = state == :pending
      def failed? = state == :failed
      def none? = state == :none
    end

    attr_reader :agent

    def initialize(agent)
      @agent = agent
    end

    # Queues seed_home unless one of this generation is already queued,
    # delivered or done; returns that command. Safe to call again.
    def issue!
      raise Unavailable, "Imported homes cannot be seeded on a VM yet" if agent.imported_home?

      placement = remote_placement!
      enrollment = Agents::RemoteRuntime.live_enrollment!(agent)
      placement.with_lock do
        store_archive!(placement) if placement.seed_sha256.blank?
        current = latest_command(placement)
        return current if current && LIVE.include?(current.state)

        RunnerCommand.enqueue!(enrollment:, kind: "seed_home", payload: {
          "container_name" => agent.container_name,
          "sha256" => placement.seed_sha256,
          "bytes" => placement.seed_archive.bytesize
        })
      end
    end

    # What the latest seed_home of this generation came to. "refused" (the
    # volume holds something else) and "unknown" (the runner restarted
    # mid-seed, possibly leaving a staging directory) are failures an
    # operator has to look at; "failed" (a fetch that broke before anything
    # was written) may be retried with issue!.
    def status
      placement = remote_placement!
      command = latest_command(placement)
      attempts = commands(placement).count
      return Status.new(state: :none, error: nil, attempts:) unless command

      case command.state
      when "done"
        placement.update!(seeded_at: command.finished_at || Time.current) if placement.seeded_at.blank?
        Status.new(state: :done, error: nil, attempts:)
      when "queued", "delivered"
        Status.new(state: :pending, error: nil, attempts:)
      else
        Status.new(state: :failed, error: "#{command.state}: #{command.result&.dig('error') || 'no detail'}", attempts:)
      end
    end

    # Only a plain failure leaves the volume untouched; anything else may have
    # written to it.
    def retryable?(status = self.status)
      status.failed? && status.error.to_s.start_with?("failed:")
    end

    private

    def remote_placement!
      placement = Agents::RemoteRuntime.placement_for(agent)
      raise Unavailable, "Resident is not placed on a VM" unless placement&.backend == "hetzner_cloud"

      placement
    end

    def commands(placement)
      RunnerCommand.where(agent_placement_id: placement.id, kind: "seed_home", generation: placement.generation)
    end

    def latest_command(placement)
      commands(placement).order(:id).last
    end

    def store_archive!(placement)
      archive = AgentIdentityExporter.new(agent).build
      raise Unavailable, "Seed archive is larger than #{MAX_BYTES} bytes" if archive.bytesize > MAX_BYTES

      placement.update!(seed_archive: archive, seed_sha256: Digest::SHA256.hexdigest(archive))
    end

  end
end
