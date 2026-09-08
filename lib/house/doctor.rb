# frozen_string_literal: true

require "ipaddr"
require "resolv"
require_relative "runner"
require_relative "env_file"

module House
  # bin/house doctor — checks this checkout's config/house.env against the
  # host it names: required keys, the embeddings digest, DNS, the host
  # itself over a read-only SSH probe, and every secret .kamal/secrets will
  # need. Prints one PASS/WARN/INFO/FAIL line per check.
  class Doctor
    Check = Struct.new(:status, :label, :detail) do
      def to_s
        detail ? "#{status}\t#{label} — #{detail}" : "#{status}\t#{label}"
      end
    end

    # Mirrors config/deploy.yml's `house.call(...)` list.
    REQUIRED_KEYS = %w[
      HOUSE_DOMAIN HOUSE_HOST HOUSE_SSH_USER HOUSE_SSH_PORT HOUSE_IMAGE
      HOUSE_REGISTRY_USER HOUSE_EMBEDDINGS_IMAGE HOUSE_AGENT_IMAGE
      HOUSE_STORAGE HOUSE_SITE_NAME
    ].freeze

    # Mirrors config/deploy.yml's `house_optional.call(...)` list.
    OPTIONAL_KEYS = %w[
      HOUSE_DOCKER_GID HOUSE_BUILDER_REMOTE HOUSE_AGENT_RUNTIME_DOCKER_HOST
      HOUSE_MAIL_FROM HOUSE_TRANSITION_ALIASES
    ].freeze

    # Mirrors .kamal/secrets' resolution of each secret.
    SECRETS = {
      "RAILS_MASTER_KEY" => "config/credentials/production.key",
      "KAMAL_REGISTRY_PASSWORD" => "config/credentials/deployment/kamal_password.key",
      "POSTGRES_PASSWORD" => "config/credentials/deployment/postgres_pw_prod.key",
      "MNEMODYNE_EMBEDDING_TOKEN" => "config/credentials/deployment/mnemodyne_embedding_token.key"
    }.freeze

    MIN_RAM_MB = 4096
    MIN_DISK_GB = 20

    REMOTE_SCRIPT = <<~SCRIPT.freeze
      echo "ARCH=$(uname -m)"
      echo "RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"
      if df -BG /var/lib/docker >/dev/null 2>&1; then
        echo "DISK_FREE_GB=$(df -BG /var/lib/docker | tail -1 | awk '{print $4}' | tr -d 'G')"
      else
        echo "DISK_FREE_GB=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')"
      fi
      echo "DOCKER=$(docker info --format '{{.OSType}}/{{.Architecture}}' 2>&1 | tr -d '\\n')"
      echo "SOCK_GID=$(stat -c %g /var/run/docker.sock 2>&1)"
    SCRIPT

    def initialize(root:, env: ENV, runner: nil, out: $stdout, stdin: $stdin)
      @root = root
      @env = env
      @out = out
      @stdin = stdin
      @runner = runner || Runner.new(user: env["HOUSE_SSH_USER"], host: env["HOUSE_HOST"], port: env["HOUSE_SSH_PORT"])
      @checks = []
    end

    # Runs every check, prints one line each, and returns a process exit
    # status: 0 unless something FAILed.
    def run
      check_required_keys
      check_optional_keys
      check_embeddings_digest
      check_dns
      remote = check_remote
      check_docker_gid(remote)
      check_secrets

      @checks.each { |check| @out.puts check }
      @checks.any? { |check| check.status == "FAIL" } ? 1 : 0
    end

    private

    def record(status, label, detail = nil)
      @checks << Check.new(status, label, detail)
    end

    def present?(value)
      value && !value.to_s.strip.empty?
    end

    def check_required_keys
      missing = REQUIRED_KEYS.reject { |key| present?(@env[key]) }
      if missing.empty?
        record("PASS", "Required HOUSE_* keys present")
      else
        record("FAIL", "Required HOUSE_* keys present", "missing #{missing.join(', ')}")
      end
    end

    def check_optional_keys
      OPTIONAL_KEYS.each do |key|
        record("INFO", key, present?(@env[key]) ? @env[key] : "(blank)")
      end
    end

    def check_embeddings_digest
      digest = @env["HOUSE_EMBEDDINGS_DIGEST"].to_s.strip
      if digest.empty?
        record("WARN", "HOUSE_EMBEDDINGS_DIGEST", "blank — run bin/house release-embeddings")
      elsif digest.match?(/\Asha256:[0-9a-f]{64}\z/)
        record("PASS", "HOUSE_EMBEDDINGS_DIGEST well-formed")
      else
        record("FAIL", "HOUSE_EMBEDDINGS_DIGEST malformed", digest)
      end
    end

    def check_dns
      domain = @env["HOUSE_DOMAIN"]
      return record("FAIL", "DNS", "HOUSE_DOMAIN is not set") unless present?(domain)

      domain_addr = resolve(domain)
      return record("FAIL", "DNS #{domain} resolves", "no A/AAAA record") unless domain_addr

      host = @env["HOUSE_HOST"]
      host_addr = ip?(host) ? host : resolve(host)
      if host_addr && domain_addr == host_addr
        record("PASS", "DNS #{domain} resolves to HOUSE_HOST", domain_addr)
      else
        record("WARN", "DNS #{domain} resolves to #{domain_addr}",
          "HOUSE_HOST is #{host} (#{host_addr || 'unresolved'}) — fine behind a tunnel or proxy")
      end
    end

    def resolve(name)
      Resolv.getaddress(name)
    rescue Resolv::ResolvError, ArgumentError
      nil
    end

    def ip?(value)
      IPAddr.new(value)
      true
    rescue IPAddr::Error, ArgumentError
      false
    end

    def check_remote
      output, ok = @runner.ssh(REMOTE_SCRIPT)
      unless ok
        record("FAIL", "SSH to HOUSE_HOST", output.strip.empty? ? "connection failed" : output.strip)
        return {}
      end

      fields = output.each_line.each_with_object({}) do |line, memo|
        key, value = line.strip.split("=", 2)
        memo[key] = value if key && value
      end

      record(fields["ARCH"] == "x86_64" ? "PASS" : "FAIL", "Architecture", fields["ARCH"] || "unknown")
      record(fields["DOCKER"].to_s.match?(%r{\Alinux/\w+\z}) ? "PASS" : "FAIL", "Docker reachable", fields["DOCKER"])

      ram = fields["RAM_MB"].to_i
      if ram >= MIN_RAM_MB
        record("PASS", "RAM", "#{ram} MB")
      else
        record("WARN", "RAM", "#{ram} MB — public/self-host.md recommends at least #{MIN_RAM_MB} MB")
      end

      disk = fields["DISK_FREE_GB"].to_i
      if disk >= MIN_DISK_GB
        record("PASS", "Free disk", "#{disk} GB")
      else
        record("WARN", "Free disk", "#{disk} GB — public/self-host.md recommends at least #{MIN_DISK_GB} GB")
      end

      fields
    end

    def check_docker_gid(remote)
      return if remote.nil? || remote.empty? # SSH already FAILed above

      observed = remote["SOCK_GID"]
      unless observed&.match?(/\A\d+\z/)
        record("FAIL", "Docker socket gid", "could not read it from the host (#{observed.inspect})")
        return
      end

      configured = @env["HOUSE_DOCKER_GID"].to_s.strip
      if configured.empty?
        if offer_to_write_gid(observed)
          record("PASS", "HOUSE_DOCKER_GID", "written as #{observed}")
        else
          record("WARN", "HOUSE_DOCKER_GID", "blank; host reports #{observed}")
        end
      elsif configured == observed
        record("PASS", "HOUSE_DOCKER_GID matches host", observed)
      else
        record("FAIL", "HOUSE_DOCKER_GID mismatch", "configured #{configured}, host reports #{observed}")
      end
    end

    def offer_to_write_gid(observed)
      @out.print "HOUSE_DOCKER_GID is blank; write #{observed} into config/house.env? [y/N] "
      answer = @stdin.gets
      return false unless answer&.strip&.downcase&.start_with?("y")

      House::EnvFile.replace_value(house_env_path, "HOUSE_DOCKER_GID", observed)
      @env["HOUSE_DOCKER_GID"] = observed
      true
    end

    def check_secrets
      SECRETS.each do |name, relative_path|
        if present?(@env[name])
          record("PASS", name, "from environment")
        elsif File.exist?(File.join(@root, relative_path))
          record("PASS", name, "from #{relative_path}")
        else
          record("FAIL", name, "not set in environment or #{relative_path}")
        end
      end
    end

    def house_env_path
      File.join(@root, "config/house.env")
    end
  end
end
