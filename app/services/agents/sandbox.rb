require "shellwords"
require "tempfile"

module Agents
  class Sandbox

    class SandboxError < StandardError; end

    REPO_PATH = "/home/agent/repo"
    WORK_PATH = "/home/agent/work"
    STATE_PATH = "/home/agent/state"
    IDENTITY_PATH = "/home/agent/identity"
    CHAOS_BUILT_IN_PROVIDER_IDS = %w[anthropic openai xai].freeze
    CHAOS_RUNTIME_PROVIDER_IDS = %w[gemini openrouter house].freeze
    SUPPORTED_CHAOS_PROVIDER_IDS = (
      CHAOS_BUILT_IN_PROVIDER_IDS + CHAOS_RUNTIME_PROVIDER_IDS
    ).freeze
    CHAOS_PROVIDER_IDS = {
      anthropic: "anthropic",
      openai: "openai",
      gemini: "gemini",
      xai: "xai",
      openrouter: "openrouter"
    }.freeze

    attr_reader :agent

    def initialize(agent)
      @agent = agent
    end

    def spawn!
      agent.with_lock do
        raise SandboxError, "Inactive resident requires explicit activation" unless agent.active?
        spawn_without_portability_gate!
      end
    end

    def spawn_without_portability_gate!
      RuntimeLocation.require_local!(agent)
      agent.github_resident_import&.require_approval!
      raise SandboxError, "agent has no supported harness" unless agent.reload.hosted?
      ensure_memory_not_suspended!
      raise SandboxError, "agent uuid missing" if agent.uuid.blank?
      raise SandboxError, "container_name missing" if agent.container_name.blank?
      raise SandboxError, "container_image missing" if agent.container_image.blank?
      raise SandboxError, "outbound_api_token missing" if agent.outbound_api_token.blank?
      raise SandboxError, "trigger_bearer_token missing" if agent.trigger_bearer_token.blank?

      Agents::Network.ensure!
      Agents::Volume.new(agent).ensure!

      if container_exists?
        if container_current?
          start!
        else
          migrate_repo_volume_from_container!
          migrate_work_volume_from_container!
          remove_container!
          run_container!
        end
      else
        run_container!
      end

      refresh_dev_endpoint! if Agents::Config.publish_ports?
      wait_for_health!
      agent.update!(runtime: "external", health_state: "healthy", consecutive_health_failures: 0)
    end

    def stale_container?
      container_exists? && !container_current?
    end

    def active_turn?
      return true if ResidentTurn.pending.where(agent: agent).exists?
      return false unless container_exists?

      result = docker_capture("exec", agent.container_name, "pgrep", "-f", "chaos exec")
      result[:ok]
    rescue StandardError
      false
    end

    def with_runtime
      RuntimeLocation.require_local!(agent)
      raise SandboxError, "agent has no supported harness" unless agent.reload.hosted?
      ensure_memory_not_suspended!
      cold_start = Agents::Config.cold_start?
      return yield unless cold_start

      spawn!
      yield
    ensure
      stop_if_idle! if cold_start
    end

    def recreate!
      agent.with_lock do
        raise SandboxError, "Inactive resident requires explicit activation" unless agent.active?
        recreate_without_portability_gate!
      end
    end

    def recreate_without_portability_gate!
      RuntimeLocation.require_local!(agent)
      agent.github_resident_import&.require_approval!
      raise SandboxError, "agent has no supported harness" unless agent.reload.hosted?
      ensure_memory_not_suspended!
      if container_exists?
        migrate_repo_volume_from_container!
        migrate_work_volume_from_container!
      end
      remove!(delete_volume: false)
      spawn!
    end

    def status
      @configuration_error = nil
      base = {
        configured: agent.container_name.present?,
        container_name: agent.container_name,
        image: agent.container_image,
        endpoint_url: agent.endpoint_url,
        configured_helixkit_app_url: safe_config_value(:internal_url),
        volume_name: agent.uuid.present? ? Agents::Volume.new(agent).volume_name : nil,
        chaos_volume_name: agent.uuid.present? ? Agents::Resources.new(agent).volumes.fetch(:chaos) : nil,
        repo_volume_name: agent.uuid.present? ? repo_volume_name : nil,
        work_volume_name: agent.uuid.present? ? work_volume_name : nil,
        state_volume_name: agent.uuid.present? ? state_volume_name : nil,
        docker_available: false,
        container_exists: false,
        identity_volume_exists: false,
        chaos_volume_exists: false,
        repo_volume_exists: false,
        work_volume_exists: false,
        state_volume_exists: false
      }
      base[:configuration_error] = @configuration_error if @configuration_error.present?

      docker_info = docker_capture("info", "--format", "{{.ServerVersion}}")
      unless docker_info[:ok]
        return base.merge(
          docker_error: docker_info[:stderr].presence || docker_info[:stdout].presence || "Docker daemon is not reachable"
        )
      end

      base[:docker_available] = true
      base[:docker_version] = docker_info[:stdout].strip
      base[:identity_volume_exists] = volume_exists?(base[:volume_name])
      base[:chaos_volume_exists] = volume_exists?(base[:chaos_volume_name])
      base[:repo_volume_exists] = volume_exists?(base[:repo_volume_name])
      base[:work_volume_exists] = volume_exists?(base[:work_volume_name])
      base[:state_volume_exists] = volume_exists?(base[:state_volume_name])
      base[:image_present] = image_present?(agent.container_image)

      if agent.container_name.present?
        inspect = docker_capture("container", "inspect", agent.container_name)
        if inspect[:ok]
          container = JSON.parse(inspect[:stdout]).first
          state = container.fetch("State", {})
          network = container.fetch("NetworkSettings", {})
          configured_image_id = image_id(agent.container_image)
          container_image_current = configured_image_id.present? && container["Image"] == configured_image_id
          container_configuration_current = container_configuration_current?(container)
          base.merge!(
            container_exists: true,
            container_id: container["Id"].to_s.first(12),
            container_image_id: container["Image"],
            configured_image_id: configured_image_id,
            container_image_current: container_image_current,
            container_configuration_current: container_configuration_current,
            image_stale: !container_image_current,
            container_stale: !container_image_current || !container_configuration_current,
            container_helixkit_app_url: container_env_value(container, "SOULSHOUSE_APP_URL") || container_env_value(container, "HELIXKIT_APP_URL"),
            container_state: state["Status"],
            container_running: state["Running"],
            container_exit_code: state["ExitCode"],
            container_error: state["Error"],
            container_started_at: state["StartedAt"],
            container_finished_at: state["FinishedAt"],
            published_ports: network["Ports"]
          )
          base[:log_tail] = logs_tail if base[:container_exists]
        else
          base[:container_error] = inspect[:stderr]
        end
      end

      base
    rescue StandardError => e
      (defined?(base) && base ? base : fallback_status).merge(docker_error: "#{e.class}: #{e.message}")
    end

    def stop!
      docker_system("stop", agent.container_name, out: File::NULL, err: File::NULL)
    end

    def start!
      agent.with_lock do
        raise SandboxError, "Inactive resident requires explicit activation" unless agent.active?
        start_without_portability_gate!
      end
    end

    def start_without_portability_gate!
      agent.github_resident_import&.require_approval!
      ensure_memory_not_suspended!
      update_restart_policy!
      docker_system("start", agent.container_name, out: File::NULL, err: File::NULL) || raise(SandboxError, "failed to start #{agent.container_name}")
    end

    def running?
      result = docker_capture("container", "inspect", "--format", "{{.State.Running}}", agent.container_name)
      result[:ok] && result[:stdout].strip == "true"
    end

    def stopped?
      container_exists? && !running?
    end

    # Verification only. No SQL writes, interactive approvals or project code.
    # A site operator grants trust through Chaos's supported interactive screen.
    def imported_runtime_trusted?
      return true unless agent.github_resident_import
      verify_resources!
      chaos_volume = Agents::Resources.new(agent).volumes.fetch(:chaos)
      unless volume_exists?(chaos_volume)
        docker_system("volume", "create", *Agents::Resources.new(agent).labels, chaos_volume) ||
          raise(SandboxError, "failed to create Chaos home")
        return false
      end
      check = <<~PYTHON
        from pathlib import Path
        import sys
        try:
            import github_import_approval
            import imported_home
            import os
            if os.environ.get('SOULSHOUSE_HOME_SYNC_STRATEGY') == 'standard':
                import standard_home_sync
                assert callable(imported_home.standard_sync_configuration)
            entrypoint = Path('/usr/local/bin/entrypoint.sh').read_text()
            assert entrypoint.index('github_import_approval.py') < entrypoint.index('runtime_hooks.py')
            assert entrypoint.index('--runtime-trust-check') < entrypoint.index('home_sync_loop.py')
        except (ImportError, OSError, ValueError, AssertionError):
            print('unsupported-managed-import-runtime')
            sys.exit(79)
        try:
            imported_home.main(['imported_home.py', '--runtime-trust-check'])
        except (ValueError, KeyError, OSError):
            sys.exit(78)
      PYTHON
      result = docker_capture("run", "--rm",
        "-v", "#{Agents::Volume.new(agent).volume_name}:#{IDENTITY_PATH}:ro",
        "-v", "#{chaos_volume}:/home/agent/.chaos:ro",
        "-e", "SOULSHOUSE_HOME_PROFILE=portable_v1",
        "-e", "SOULSHOUSE_HOME_ROOT=#{IDENTITY_PATH}",
        "-e", "SOULSHOUSE_PORTABLE_HOME_ID=#{agent.portable_home_id}",
        "-e", "SOULSHOUSE_HOME_SYNC_STRATEGY=#{agent.github_resident_import.sync_strategy}",
        "-e", "SOULSHOUSE_HOME_SYNC_CONFIGURATION=#{agent.github_resident_import.sync_configuration.to_json}",
        "-e", "SOULSHOUSE_GITHUB_IMPORT_REQUIRE_OAUTH_TRUST=#{managed_import_oauth_trust_required? ? '1' : '0'}",
        "--entrypoint", "python3", agent.container_image,
        "-c", check)
      raise SandboxError, "Runtime image does not support managed GitHub imports" if result[:stdout].to_s.include?("unsupported-managed-import-runtime")
      result[:ok]
    end

    def stop_if_idle!
      return unless running?
      return if active_turn?
      return if AgentRuntimeInteraction.where(agent: agent).active.exists?

      stop!
    end

    def remove!(delete_volume: false)
      remove_container!
      if delete_volume
        Agents::Volume.new(agent).destroy!
        destroy_repo_volume!
        destroy_work_volume!
        destroy_state_volume!
        if LocalInstance.current.namespace
          docker_system("volume", "rm", "-f", Agents::Resources.new(agent).volumes.fetch(:chaos), out: File::NULL, err: File::NULL)
        end
      end
    end

    # Runs a command inside the running container as the agent user and
    # returns { stdout:, stderr:, ok: }. Never starts the container.
    def exec_as_agent(*command, timeout_seconds: 60)
      raise SandboxError, "#{agent.container_name} is not running" unless running?

      docker_capture(
        "exec", "-u", "agent", "-e", "HOME=/home/agent", agent.container_name,
        "timeout", timeout_seconds.to_s, *command
      )
    end

    def healthy?
      uri = URI("#{Agents::Endpoint.url_for(agent)}/health")
      Net::HTTP.get_response(uri).code == "200"
    rescue StandardError
      false
    end

    private :spawn_without_portability_gate!, :start_without_portability_gate!, :recreate_without_portability_gate!

    private

    def ensure_memory_not_suspended!
      if agent.memory_vault&.suspended_at?
        raise SandboxError, "Resident memory is suspended; verify the checkpoint before resuming"
      end
    end

    def verify_resources!
      Agents::Resources.new(agent).verify_existing!
    end

    def docker_system(*args, **options)
      verify_resources!
      system("docker", *args, **options)
    end

    def docker_capture(*args)
      verify_resources!
      stdout, stderr, status = Open3.capture3("docker", *args)
      { stdout: stdout, stderr: stderr, ok: status.success? }
    end

    def safe_config_value(name)
      Agents::Config.public_send(name)
    rescue KeyError => e
      @configuration_error = "#{e.class}: #{e.message}"
      nil
    end

    def fallback_status
      {
        configured: agent.container_name.present?,
        container_name: agent.container_name,
        image: agent.container_image,
        endpoint_url: agent.endpoint_url,
        configured_helixkit_app_url: nil,
        volume_name: nil,
        chaos_volume_name: nil,
        repo_volume_name: nil,
        work_volume_name: nil,
        state_volume_name: nil,
        docker_available: false,
        container_exists: false,
        identity_volume_exists: false,
        chaos_volume_exists: false,
        repo_volume_exists: false,
        work_volume_exists: false,
        state_volume_exists: false
      }
    end

    def volume_exists?(name)
      return false if name.blank?
      docker_capture("volume", "inspect", name)[:ok]
    end

    def image_present?(image)
      image_id(image).present?
    end

    def image_id(image)
      return nil if image.blank?
      result = docker_capture("image", "inspect", "--format", "{{.Id}}", image)
      result[:ok] ? result[:stdout].strip.presence : nil
    end

    def image_current?(container_image_id, configured_image)
      configured_image_id = image_id(configured_image)
      configured_image_id.present? && container_image_id == configured_image_id
    end

    def container_env_value(container, name)
      Array(container.dig("Config", "Env")).find { |entry| entry.start_with?("#{name}=") }&.split("=", 2)&.last
    end

    def logs_tail
      result = docker_capture("logs", "--tail", "30", agent.container_name)
      [ result[:stdout], result[:stderr] ].compact.join("
").strip.presence
    end

    def container_exists?
      docker_system("container", "inspect", agent.container_name, out: File::NULL, err: File::NULL)
    end

    def container_current?
      inspect = docker_capture("container", "inspect", agent.container_name)
      return false unless inspect[:ok]

      container = JSON.parse(inspect[:stdout]).first
      image_current?(container["Image"], agent.container_image) && container_configuration_current?(container)
    rescue StandardError
      false
    end

    def container_configuration_current?(container)
      Array(container["Mounts"]).none? do |mount|
        mount["Type"] == "bind" && mount["Destination"] == "/run/helixkit-source.yml"
      end
    end

    def remove_container!
      docker_system("rm", "-f", agent.container_name, out: File::NULL, err: File::NULL)
    end

    def repo_volume_name
      Agents::Resources.new(agent).volumes.fetch(:repo)
    end

    def ensure_repo_volume!
      return true if volume_exists?(repo_volume_name)

      docker_system("volume", "create", *Agents::Resources.new(agent).labels, repo_volume_name, out: File::NULL, err: File::NULL) || raise(SandboxError, "failed to create docker volume #{repo_volume_name}")
    end

    def destroy_repo_volume!
      docker_system("volume", "rm", "-f", repo_volume_name, out: File::NULL, err: File::NULL) if agent.uuid.present?
    end

    def work_volume_name
      Agents::Resources.new(agent).volumes.fetch(:work)
    end

    def ensure_work_volume!
      return true if volume_exists?(work_volume_name)

      docker_system("volume", "create", *Agents::Resources.new(agent).labels, work_volume_name, out: File::NULL, err: File::NULL) || raise(SandboxError, "failed to create docker volume #{work_volume_name}")
    end

    def destroy_work_volume!
      docker_system("volume", "rm", "-f", work_volume_name, out: File::NULL, err: File::NULL) if agent.uuid.present?
    end

    def state_volume_name
      Agents::Resources.new(agent).volumes.fetch(:state)
    end

    def ensure_state_volume!
      return true if volume_exists?(state_volume_name)

      docker_system("volume", "create", *Agents::Resources.new(agent).labels, state_volume_name, out: File::NULL, err: File::NULL) || raise(SandboxError, "failed to create docker volume #{state_volume_name}")
    end

    def destroy_state_volume!
      docker_system("volume", "rm", "-f", state_volume_name, out: File::NULL, err: File::NULL) if agent.uuid.present?
    end

    def migrate_repo_volume_from_container!
      ensure_repo_volume!
      return true if repo_volume_populated?

      copy_container_directory_to_volume!(REPO_PATH, repo_volume_name, "/repo")
    end

    def migrate_work_volume_from_container!
      ensure_work_volume!
      return true if work_volume_populated?
      return true unless container_directory_exists?(WORK_PATH)

      copy_container_directory_to_volume!(WORK_PATH, work_volume_name, "/work")
    end

    def copy_container_directory_to_volume!(source_path, volume_name, destination_path)
      source = "#{agent.container_name}:#{source_path}/."
      destination_mount = "#{volume_name}:#{destination_path}"
      cmd = [
        "docker cp #{Shellwords.escape(source)} -",
        "docker run --rm -i -v #{Shellwords.escape(destination_mount)} busybox tar xf - -C #{Shellwords.escape(destination_path)}"
      ].join(" | ")
      verify_resources!
      raise SandboxError, "failed to migrate #{source_path} into #{volume_name}" unless system(cmd, out: File::NULL, err: File::NULL)
    end

    def repo_volume_populated?
      volume_populated?(repo_volume_name, "/repo")
    end

    def work_volume_populated?
      volume_populated?(work_volume_name, "/work")
    end

    def volume_populated?(volume_name, mount_path)
      result = docker_capture(
        "run", "--rm", "-v", "#{volume_name}:#{mount_path}:ro", "busybox", "sh", "-c",
        "test -n \"$(find #{mount_path} -mindepth 1 -print -quit)\""
      )
      result[:ok]
    end

    def container_directory_exists?(path)
      docker_capture("exec", agent.container_name, "test", "-d", path)[:ok]
    end

    def run_container!
      verify_resources!
      ensure_repo_volume!
      ensure_work_volume!
      ensure_state_volume!
      chaos_volume = Agents::Resources.new(agent).volumes.fetch(:chaos)
      unless volume_exists?(chaos_volume)
        docker_system("volume", "create", *Agents::Resources.new(agent).labels, chaos_volume) || raise(SandboxError, "failed to create Chaos home")
      end
      service_manifest_file = build_service_manifest_file
      container_created = false
      args = [
        "docker", "create",
        "--name", agent.container_name,
        "--hostname", Agents::Resources.new(agent).hostname,
        *Agents::Resources.new(agent).labels,
        "--network", Agents::Config.network,
        "--restart", Agents::Config.restart_policy,
        "--memory", "#{agent.container_memory_mb}m",
        "--cpu-shares", agent.container_cpu_shares.to_s,
        "-v", "#{Agents::Volume.new(agent).volume_name}:/home/agent/identity",
        "-v", "#{Agents::Resources.new(agent).volumes.fetch(:chaos)}:/home/agent/.chaos",
        "-v", "#{repo_volume_name}:#{REPO_PATH}",
        "-v", "#{work_volume_name}:#{WORK_PATH}",
         "-v", "#{state_volume_name}:#{STATE_PATH}",
        "--tmpfs", "/run/helixkit:rw,noexec,nosuid,nodev,mode=0700",
        "-e", "AGENT_ID=#{agent.uuid}",
        "-e", "AGENT_SLUG=#{agent_slug}",
        "-e", "AGENT_PROVIDER=#{agent_provider}",
        "-e", "AGENT_DEFAULT_MODEL=#{agent_model}",
        "-e", "TRIGGER_BEARER_TOKEN=#{agent.trigger_bearer_token}",
        "-e", "SOULSHOUSE_BEARER_TOKEN=#{agent.outbound_api_token}",
        "-e", "SOULSHOUSE_APP_URL=#{Agents::Config.internal_url}",
        "-e", "SOULSHOUSE_ACTIVITY_ORIGIN=#{ENV.fetch('SOULSHOUSE_ACTIVITY_ORIGIN', Agents::Config.internal_url)}",
        # legacy alias: residents' notes and habits may reference the old name; keep indefinitely
        "-e", "HELIXKIT_BEARER_TOKEN=#{agent.outbound_api_token}",
        "-e", "HELIXKIT_APP_URL=#{Agents::Config.internal_url}"
      ]
      args += home_profile_env_args
      args += house_trust_env_args
      args += provider_env_args
      args += [ "-p", "127.0.0.1::4000" ] if Agents::Config.publish_ports?
      args << agent.container_image

      _stdout, stderr, status = Open3.capture3(*args)
      raise SandboxError, "docker create failed: #{stderr}" unless status.success?

      container_created = true
      _stdout, stderr, status = Open3.capture3(
        "docker", "cp", service_manifest_file.path, "#{agent.container_name}:/run/helixkit-source.yml"
      )
      raise SandboxError, "docker cp failed: #{stderr}" unless status.success?

      _stdout, stderr, status = Open3.capture3("docker", "start", agent.container_name)
      raise SandboxError, "docker start failed: #{stderr}" unless status.success?
    rescue StandardError
      remove_container! if container_created
      raise
    ensure
      service_manifest_file&.close!
    end

    def update_restart_policy!
      docker_system(
        "update", "--restart", Agents::Config.restart_policy, agent.container_name,
        out: File::NULL, err: File::NULL
      ) || raise(SandboxError, "failed to update restart policy for #{agent.container_name}")
    end

    def build_service_manifest_file
      file = Tempfile.new([ "helixkit-services-", ".yml" ])
      file.chmod(0o600)
      file.write(Agents::ServiceManifest.new(agent).to_yaml)
      file.flush
      file
    end

    def refresh_dev_endpoint!
      verify_resources!
      stdout, stderr, status = Open3.capture3("docker", "port", agent.container_name, "4000/tcp")
      raise SandboxError, "docker port failed: #{stderr}" unless status.success?

      host_port = stdout.lines.first.to_s.strip
      raise SandboxError, "docker port returned no mapping for #{agent.container_name}" if host_port.blank?

      host, port = host_port.split(":", 2)
      host = "127.0.0.1" if host == "0.0.0.0" || host == "::"
      agent.update!(endpoint_url: "http://#{host}:#{port}")
    end

    def wait_for_health!
      30.times do
        return true if healthy?
        sleep 1
      end
      raise SandboxError, "container did not become healthy within 30s"
    end

    def agent_slug
      agent.name.to_s.parameterize.presence || agent.uuid
    end

    def agent_provider
      self.class.chaos_provider_for(agent)
    end

    def self.chaos_provider_for(agent)
      chaos_selection_for(agent).fetch(:provider)
    end

    def self.chaos_model_for(agent)
      chaos_selection_for(agent).fetch(:model)
    end

    # `model_id` defaults to the resident's own; a conversation that selected
    # another model passes it here (see Agents::ModelSelection).
    def self.chaos_selection_for(agent, model_id: agent.model_id)
      model_id = model_id.to_s
      if HouseInference::Offering.find(model_id)
        return { provider: "house", model: model_id }
      end

      subscription_provider = subscription_provider_for(agent, model_id: model_id)
      if subscription_provider && agent.provider_auth_mode(subscription_provider) == "oauth_account"
        return {
          provider: subscription_provider,
          model: Chat.model_config(model_id).fetch(:provider_model_id)
        }
      end

      selection = ResolvesProvider.resolve_provider(model_id, account: agent.account)
      {
        provider: CHAOS_PROVIDER_IDS.fetch(selection.fetch(:provider)),
        model: selection.fetch(:model_id)
      }
    end

    def self.subscription_provider_for(agent, model_id: agent.model_id)
      model_id = model_id.to_s
      return unless Chat.model_config(model_id)&.dig(:provider_model_id)

      provider = case model_id
      when /\Aanthropic\// then "anthropic"
      when /\Agoogle\// then "gemini"
      when /\Aopenai\// then "openai"
      when /\Ax-ai\// then "xai"
      end
      provider if Agent::OAUTH_ACCOUNT_PROVIDERS.include?(provider)
    end

    def agent_model
      self.class.chaos_model_for(agent)
    end

    # The resident's actual profile goes into the container, never a literal.
    # mira_v1 produces exactly the arguments it always has.
    # An unknown stored profile is refused here too, so a row that bypassed
    # validation can never start as a house resident or as another profile.
    def home_profile_env_args
      unless Agent::HOME_PROFILES.include?(agent.home_profile)
        raise SandboxError, "unknown resident home profile #{agent.home_profile.inspect}"
      end
      return [] unless agent.imported_home?

      args = [ "-e", "SOULSHOUSE_HOME_PROFILE=#{agent.home_profile}",
               "-e", "SOULSHOUSE_PORTABLE_HOME_ID=#{agent.portable_home_id}",
               "-e", "#{agent.imported_home_root_env}=#{IDENTITY_PATH}",
               "-e", "AGENT_REPO_PATH=#{IDENTITY_PATH}",
               "-e", "TZ=Europe/Madrid" ]
      # Default off. Only the Anthropic-subscription clamp combination reads it.
      args += [ "-e", "SOULSHOUSE_IMPORTED_CLAMP_OMIT_FORCED_LOGIN=1" ] if Agents::Config.imported_clamp_omit_forced_login?
      if (request = agent.github_resident_import)
        request.require_approval!
        args += [ "-e", "SOULSHOUSE_GITHUB_IMPORT_ID=#{request.id}",
          "-e", "SOULSHOUSE_GITHUB_IMPORT_FINGERPRINT=#{request.approved_credential_fingerprint}",
          "-e", "SOULSHOUSE_GITHUB_IMPORT_REPOSITORY=#{request.repository}",
          "-e", "SOULSHOUSE_GITHUB_IMPORT_BRANCH=#{request.branch}",
          "-e", "SOULSHOUSE_HOME_SYNC_STRATEGY=#{request.sync_strategy}",
          "-e", "SOULSHOUSE_HOME_SYNC_CONFIGURATION=#{request.sync_configuration.to_json}",
          "-e", "SOULSHOUSE_GITHUB_IMPORT_CONNECTION=#{request.service_connection.public_id}" ]
        args += [ "-e", "SOULSHOUSE_GITHUB_IMPORT_REQUIRE_OAUTH_TRUST=1" ] if managed_import_oauth_trust_required?
      end
      args
    end

    # Default off; adds nothing to docker create unless the host enables it.
    def house_trust_env_args
      return [] if agent.imported_home? || !Agents::Config.require_house_trust?

      [ "-e", "SOULSHOUSE_REQUIRE_HOUSE_TRUST=1" ]
    end

    def provider_env_args
      return [] if HouseInference::Offering.find(agent.model_id)

      agent.account.ai_provider_keys.filter_map do |name, value|
        value.present? ? [ "-e", "#{name}=#{value}" ] : nil
      end.flatten
    end

    def managed_import_oauth_trust_required?
      provider = self.class.subscription_provider_for(agent)
      provider.in?(%w[openai xai]) && agent.provider_auth_mode(provider) == "oauth_account"
    end

  end
end
