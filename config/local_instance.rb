# frozen_string_literal: true

# Deliberately Rails-independent: Rails, Vite, shell and Playwright use this file.
require "digest"
require "fileutils"
require "json"

module LocalInstance

  class Error < StandardError; end

  ROOT = File.realpath("..", __dir__)
  PORTS = { web: 3100, component: 3101, vite: 3036, vite_test: 3037, backend: 3200 }.freeze

  def self.current
    Configuration.new(root: ROOT, env: ENV, environment: ENV.fetch("RAILS_ENV", "development"))
  end

  class Configuration

    attr_reader :root, :environment

    def initialize(root:, env:, environment: "development")
      @root = File.realpath(root)
      @env = env
      @environment = environment
    end

    def local?
      %w[development test].include?(environment)
    end

    def number
      value = @env["SOULSHOUSE_INSTANCE"]
      if value.nil?
        match = File.basename(root).match(/\Asouls-house(?:-([0-9]+))?\z/)
        raise Error, "Unrecognised checkout name; set SOULSHOUSE_INSTANCE explicitly (0–9)" unless match
        value = match[1] || "0"
      end
      raise Error, "SOULSHOUSE_INSTANCE must be a single integer from 0 to 9" unless value.match?(/\A[0-9]\z/)
      value.to_i
    end

    def port(role)
      PORTS.fetch(role) + number * 10
    end

    def web_port
      return 3100 unless local?
      # Keep existing primary launch overrides working. Secondary ports are fixed.
      if number.zero?
        Integer(@env["SOULSHOUSE_DEV_WEB_PORT"] || @env["HELIXKIT_DEV_WEB_PORT"] || port(:web))
      else
        port(:web)
      end
    end

    def database(environment, role = :primary)
      raise Error, "Not a local database environment" unless %w[development test].include?(environment)
      base = !local? || number.zero? ? "helix_kit_#{environment}" : "souls_house_#{environment}_#{number}"
      role.to_sym == :primary ? base : "#{base}_#{role}"
    end

    def namespace
      return nil unless local?
      return nil if environment == "development" && number.zero?
      "souls-house-#{number}-#{environment}"
    end

    def image
      number.zero? ? "helixkit-agent-runtime:local" : "souls-house-agent-runtime:local-#{number}"
    end

    def cookie(name)
      return name unless local?
      return name if number.zero? && environment == "development"
      "#{name}_souls_#{number}_#{environment}"
    end

    def fingerprint
      Digest::SHA256.hexdigest([ root, number, environment ].join(":"))[0, 24]
    end

    def validate!
      return unless local?
      number
      # Rails merges these over database.yml. Reject before Rails can connect;
      # never echo a connection URL (it can contain a password).
      overrides = @env.keys.grep(/\A(?:.*_)?DATABASE_URL\z/).select { |key| !@env[key].to_s.empty? }
      raise Error, "Local database URL overrides are unsafe: #{overrides.join(', ')}. Unset them." unless overrides.empty?
      if @env["PGSERVICE"] || (@env["PGHOST"] && !@env["PGHOST"].match?(/\A(?:localhost|127\.0\.0\.1|::1|\/.*)\z/))
        raise Error, "Local instances require a local PostgreSQL host and no PGSERVICE override"
      end
      return if number.zero?
      expected_callback = "http://host.docker.internal:#{environment == "test" ? port(:backend) : web_port}"
      if @env["SOULSHOUSE_AGENT_INTERNAL_URL"] && @env["SOULSHOUSE_AGENT_INTERNAL_URL"] != expected_callback
        raise Error, "SOULSHOUSE_AGENT_INTERNAL_URL conflicts with this local instance/environment"
      end
      { "SOULSHOUSE_DEV_WEB_PORT" => port(:web), "HELIXKIT_DEV_WEB_PORT" => port(:web) }.each do |key, expected|
        if @env[key] && @env[key] != expected.to_s
          raise Error, "#{key} conflicts with instance #{number}"
        end
      end
    end

    # A persistent claim protects ordinary rails test/console/db commands too,
    # not just bin/dev. Delete a claim only after retiring the old checkout.
    def claim!(directory: File.join(Dir.home, ".local/state/souls-house/instances"))
      return unless local?
      validate!
      FileUtils.mkdir_p(directory, mode: 0o700)
      File.open(File.join(directory, "#{number}.json"), File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        saved = file.read
        owner = JSON.parse(saved).fetch("root") unless saved.empty?
        if owner && owner != root
          raise Error, "Instance #{number} belongs to #{owner}. Choose another number or explicitly retire its claim in #{directory}."
        end
        file.rewind
        file.write(JSON.generate(root: root))
        file.truncate(file.pos)
      end
    end

    def configure!
      return unless local?
      claim!
      @env["SOULSHOUSE_INSTANCE"] = number.to_s
      @env["SOULSHOUSE_DEV_WEB_PORT"] = web_port.to_s
      @env["VITE_RUBY_PORT"] = port(environment == "test" ? :vite_test : :vite).to_s
      @env["PORT"] ||= (environment == "test" ? port(:backend) : web_port).to_s
      @env["PIDFILE"] ||= File.join(root, "tmp/pids/#{environment == "development" ? "server" : "test"}.pid")
    end

    def to_h
      validate!
      {
        instance: number, checkout: root, environment: environment,
        rails_url: "http://localhost:#{web_port}", vite_url: "http://localhost:#{port(:vite)}",
        playwright_url: "http://127.0.0.1:#{port(:backend)}", ports: PORTS.keys.to_h { |key| [ key, port(key) ] },
        development_databases: %i[primary cache queue cable].to_h { |role| [ role, database("development", role) ] },
        test_database: database("test"), docker_network: namespace ? "#{namespace}-agents" : @env.fetch("SOULSHOUSE_AGENTS_NETWORK", "helixkit_agents"), docker_namespace: namespace || "legacy primary", image: image,
        fingerprint: fingerprint, session_cookie: cookie("session_id")
      }
    end

  end

  class Middleware

    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      headers = headers.merge("x-souls-house-instance" => LocalInstance.current.fingerprint)
      headers["x-souls-house-server"] = ENV["SOULSHOUSE_SERVER_TOKEN"] if ENV["SOULSHOUSE_SERVER_TOKEN"]
      [ status, headers, body ]
    end

  end

end
