module Agents
  # The house side of seed_home (#246 slice 3): a new VM resident's first home.
  #
  # The archive is the same AgentIdentityExporter tarball a local resident is
  # seeded from. It is built once per placement and stored with its digest, so
  # every later seed_home names the same bytes: a runner that already unpacked
  # them answers "done", and one holding anything else refuses. The runner
  # fetches the archive by digest (RunnerEnrollment#authorize_seed!).
  #
  # An archive import (placement kind archive_import) is seeded per role
  # (docs/2026-10-10-vm-imports.md, point 1): identity, repo and work each
  # get their own seed_home naming the role's staged tarball
  # (AgentImportStage), under the same digest, marker and refusal rules, one
  # volume each. A birth seeds identity only, with the payload it always had.
  #
  # GitHub-imported homes are not seeded here yet: their reviewed home has to
  # reach the VM by a path of its own (slice 2).
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

    # Queues seed_home for each role unless one of this generation is
    # already queued, delivered or done for it. Safe to call again. Returns
    # the identity command for a birth, and the commands by role for an
    # archive import.
    def issue!
      raise Unavailable, "Imported homes cannot be seeded on a VM yet" if agent.imported_home?

      placement = remote_placement!
      enrollment = Agents::RemoteRuntime.live_enrollment!(agent)
      require_role_support!(enrollment) if import?(placement)
      placement.with_lock do
        issued = roles(placement).to_h do |role|
          sha256, bytes = archive_for!(placement, role)
          current = latest_command(placement, role)
          next [ role, current ] if current && LIVE.include?(current.state)

          payload = { "container_name" => agent.container_name, "sha256" => sha256, "bytes" => bytes }
          payload["role"] = role if import?(placement)
          [ role, RunnerCommand.enqueue!(enrollment:, kind: "seed_home", payload:, seed_role: (role if import?(placement))) ]
        end
        import?(placement) ? issued : issued.fetch("identity")
      end
    end

    # What the latest seed_home of this generation came to, across roles: done
    # only when every role is done; pending while any is in flight; failed if
    # any failed. "refused" (the volume holds something else) and "unknown"
    # (the runner restarted mid-seed, possibly leaving a staging directory)
    # are failures an operator has to look at; "failed" (a fetch that broke
    # before anything was written) may be retried with issue!. attempts is
    # the most any one role has used.
    def status
      placement = remote_placement!
      latest = roles(placement).to_h { |role| [ role, latest_command(placement, role) ] }
      attempts = roles(placement).map { |role| commands(placement, role).count }.max.to_i
      return Status.new(state: :none, error: nil, attempts:) if latest.values.all?(&:nil?)

      failed = latest.select { |_, command| command && !LIVE.include?(command.state) }
      if failed.any?
        error = failed.map do |role, command|
          detail = "#{command.state}: #{command.result&.dig('error') || 'no detail'}"
          import?(placement) ? "#{role} #{detail}" : detail
        end.join("; ")
        return Status.new(state: :failed, error:, attempts:)
      end
      if latest.values.all? { |command| command&.state == "done" }
        finished = latest.values.filter_map(&:finished_at).max || Time.current
        placement.update!(seeded_at: finished) if placement.seeded_at.blank?
        return Status.new(state: :done, error: nil, attempts:)
      end
      Status.new(state: :pending, error: nil, attempts:)
    end

    # Only a plain failure leaves a volume untouched; anything else may have
    # written to it. Every failed role must be a plain failure.
    def retryable?(status = self.status)
      status.failed? && status.error.to_s.split("; ").all? { |part| part.sub(/\A(identity|repo|work) /, "").start_with?("failed:") }
    end

    private

    def remote_placement!
      placement = Agents::RemoteRuntime.placement_for(agent)
      raise Unavailable, "Resident is not placed on a VM" unless placement&.backend == "hetzner_cloud"

      placement
    end

    def import?(placement) = placement.kind == "archive_import"

    # A runner from before seed roles ignores role and seeds identity: an
    # empty identity volume would take the repo home, and identical digests
    # would report every role done with repo and work never written. So the
    # runner must say, in the facts it last reported, that it seeds each role
    # into its own volume; otherwise nothing is queued (Mira's review of #444).
    def require_role_support!(enrollment)
      roles = enrollment.reload.last_facts.to_h["seed_roles"]
      return if roles.is_a?(Array) && (AgentImportStage::ROLES - roles).empty?

      raise Unavailable, "This resident's server runner cannot seed an imported home yet; it needs a newer runner"
    end

    def roles(placement) = import?(placement) ? AgentImportStage::ROLES : %w[identity]

    def commands(placement, role)
      RunnerCommand.where(agent_placement_id: placement.id, kind: "seed_home", generation: placement.generation,
        seed_role: import?(placement) ? role : nil).order(:id)
    end

    def latest_command(placement, role)
      commands(placement, role).last
    end

    # [sha256, bytes] of the role's archive. A birth's is built once and kept
    # on the placement; an import's was staged when it was imported.
    def archive_for!(placement, role)
      if import?(placement)
        stage = agent.import_stages.find_by(role:) || raise(Unavailable, "The #{role} home was not staged")
        [ stage.sha256, stage.bytes ]
      else
        store_archive!(placement) if placement.seed_sha256.blank?
        [ placement.seed_sha256, placement.seed_archive.bytesize ]
      end
    end

    def store_archive!(placement)
      archive = AgentIdentityExporter.new(agent).build
      raise Unavailable, "Seed archive is larger than #{MAX_BYTES} bytes" if archive.bytesize > MAX_BYTES

      placement.update!(seed_archive: archive, seed_sha256: Digest::SHA256.hexdigest(archive))
    end

  end
end
