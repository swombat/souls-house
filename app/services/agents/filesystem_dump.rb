module Agents
  class FilesystemDump

    require "shellwords"

    MAX_ENTRIES = 5_000
    MAX_DEPTH = 6
    MAX_FILE_BYTES = 4_000
    IDENTITY_ROOT = "/home/agent/identity"
    CONTAINER_HOME_ROOT = "/home/agent"
    EXCLUDED_CONTAINER_PATHS = %w[
      ./.chaos
      ./.chaos/*
      ./state
      ./state/*
    ].freeze
    PREVIEWABLE_EXTENSIONS = %w[
      .md .txt .json .yml .yaml .toml .env .gitignore .rb .js .ts .svelte .py .sh
    ].freeze

    attr_reader :agent, :target

    def initialize(agent, target: :identity)
      @agent = agent
      @target = target.to_sym
    end

    def as_json
      return unavailable("agent uuid missing") if agent.uuid.blank?
      return unavailable("Docker daemon is not reachable") unless docker_ok?
      return unavailable("identity volume is missing") if identity? && !volume_exists?
      return unavailable("container is not configured") if container_home? && agent.container_name.blank?
      return unavailable("container is not running") if container_home? && !container_running?

      entries = list_entries.map { |entry| entry_json(entry) }

      {
        root: root,
        volume_name: volume.volume_name,
        container_name: agent.container_name,
        target: target,
        truncated: truncated?,
        entries: entries
      }
    rescue StandardError => e
      unavailable("#{e.class}: #{e.message}")
    end

    def file_preview_json(path)
      return unavailable_preview("agent uuid missing") if agent.uuid.blank?

      relative_path = normalize_relative_path(path)
      return unavailable_preview("invalid path") if relative_path.blank?
      return unavailable_preview("path is private") if container_home? && excluded_container_path?(relative_path)
      return unavailable_preview("unsupported file type") unless previewable_path?(relative_path)

      return unavailable_preview("Docker daemon is not reachable") unless docker_ok?
      return unavailable_preview("identity volume is missing") if identity? && !volume_exists?
      return unavailable_preview("container is not configured") if container_home? && agent.container_name.blank?
      return unavailable_preview("container is not running") if container_home? && !container_running?

      result = docker_run("head", "-c", MAX_FILE_BYTES.to_s, relative_path)
      return unavailable_preview("could not read file") unless result[:ok]

      content = result[:stdout].to_s
      return unavailable_preview("binary-looking content") if content.include?("\u0000")

      size_result = docker_run("wc", "-c", relative_path)
      size = size_result[:ok] ? size_result[:stdout].to_s.split.first.to_i : nil

      {
        path: relative_path.delete_prefix("./"),
        target: target,
        previewable: true,
        content: content,
        size_bytes: size,
        truncated: size.present? && size > MAX_FILE_BYTES
      }
    rescue StandardError => e
      unavailable_preview("#{e.class}: #{e.message}")
    end

    private

    def unavailable(error)
      {
        root: root,
        volume_name: agent.uuid.present? ? volume.volume_name : nil,
        container_name: agent.container_name,
        target: target,
        error: error,
        entries: []
      }
    end

    def unavailable_preview(error)
      {
        target: target,
        error: error,
        previewable: false
      }
    end

    def normalize_relative_path(path)
      cleaned = path.to_s.delete_prefix("./")
      return nil if cleaned.blank? || cleaned.start_with?("/")

      parts = cleaned.split("/")
      return nil if parts.any? { |part| part.blank? || part == "." || part == ".." }

      "./#{cleaned}"
    end

    def docker_ok?
      docker_capture("info", "--format", "{{.ServerVersion}}")[:ok]
    end

    def volume_exists?
      docker_capture("volume", "inspect", volume.volume_name)[:ok]
    end

    def container_running?
      result = docker_capture("container", "inspect", "--format", "{{.State.Running}}", agent.container_name)
      result[:ok] && result[:stdout].strip == "true"
    end

    def list_entries
      @list_entries ||= begin
        result = find_entries
        return [] unless result[:ok]

        parsed = result[:stdout].lines.filter_map do |line|
          type, size, path = line.chomp.split("\t", 3)
          next if path.blank? || path == "."

          {
            path: path,
            type: type == "directory" ? "directory" : "file",
            size_bytes: size.present? ? size.to_i : nil
          }
        end

        @truncated = parsed.length > MAX_ENTRIES
        parsed.first(MAX_ENTRIES)
      end
    end

    def truncated?
      list_entries
      @truncated == true
    end

    def entry_json(entry)
      relative_path = entry.fetch(:path)
      type = entry.fetch(:type)
      json = {
        path: relative_path.delete_prefix("./"),
        name: File.basename(relative_path),
        type: type,
        depth: relative_path.delete_prefix("./").count("/")
      }

      return json if type == "directory"

      json.merge!(size_bytes: entry[:size_bytes])
      json.merge!(previewable: previewable_path?(relative_path))
      json
    end

    def docker_run(*command)
      return container_home_run(*command) if container_home?

      docker_capture(
        "run", "--rm",
        "-v", "#{volume.volume_name}:/identity:ro",
        "-w", "/identity",
        "busybox",
        *command
      )
    end

    def find_entries
      return container_home_find if container_home?

      docker_run("sh", "-c", metadata_script("find . -maxdepth #{MAX_DEPTH} -print"))
    end

    def container_home_find
      docker_capture(
        "exec",
        agent.container_name,
        "sh",
        "-c",
        "cd /home/agent && #{metadata_script("find . -maxdepth #{MAX_DEPTH} \\( -path './.chaos' -o -path './.chaos/*' -o -path './state' -o -path './state/*' \\) -prune -o -print")}"
      )
    end

    def metadata_script(find_command)
      %(#{find_command} | sort | head -n #{MAX_ENTRIES + 2} | while IFS= read -r path; do [ "$path" = "." ] && continue; if [ -d "$path" ]; then printf 'directory\\t\\t%s\\n' "$path"; else size=$(wc -c < "$path" 2>/dev/null || true); printf 'file\\t%s\\t%s\\n' "$size" "$path"; fi; done)
    end

    def previewable_path?(relative_path)
      extension = File.extname(relative_path)
      PREVIEWABLE_EXTENSIONS.include?(extension) || extension.blank?
    end

    def excluded_container_path?(relative_path)
      relative_path == "./.chaos" ||
        relative_path.start_with?("./.chaos/") ||
        relative_path == "./state" ||
        relative_path.start_with?("./state/")
    end

    def container_home_run(*command)
      escaped_command = command.map { |part| Shellwords.escape(part.to_s) }.join(" ")
      docker_capture(
        "exec",
        agent.container_name,
        "sh",
        "-c",
        "cd /home/agent && #{escaped_command}"
      )
    end

    def docker_capture(*args)
      Agents::Resources.new(agent).verify_existing!
      stdout, stderr, status = Open3.capture3("docker", *args)
      { stdout: stdout, stderr: stderr, ok: status.success? }
    end

    def volume
      @volume ||= Agents::Volume.new(agent)
    end

    def identity?
      target == :identity
    end

    def container_home?
      target == :container_home
    end

    def root
      container_home? ? CONTAINER_HOME_ROOT : IDENTITY_ROOT
    end

  end
end
