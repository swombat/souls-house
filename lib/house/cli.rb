# frozen_string_literal: true

require_relative "../../config/house"
require_relative "runner"
require_relative "env_file"
require_relative "init"
require_relative "doctor"
require_relative "release_embeddings"

# House::Cli — bin/house's subcommands. See config/house.env.example and
# docs/2026-09-07-forkable-house-plan-from-lume.md. Loadable on its own
# (without executing anything) so it can be required from tests; bin/house
# is the thin executable wrapper.
class House::Cli
  HOUSE_KEYS = %w[
    HOUSE_DOMAIN
    HOUSE_HOST
    HOUSE_SSH_USER
    HOUSE_SSH_PORT
    HOUSE_IMAGE
    HOUSE_REGISTRY_USER
    HOUSE_EMBEDDINGS_IMAGE
    HOUSE_EMBEDDINGS_DIGEST
    HOUSE_DOCKER_GID
    HOUSE_BUILDER_REMOTE
    HOUSE_AGENT_IMAGE
    HOUSE_AGENT_RUNTIME_DOCKER_HOST
    HOUSE_STORAGE
    HOUSE_SITE_NAME
    HOUSE_MAIL_FROM
    HOUSE_TRANSITION_ALIASES
  ].freeze

  class << self
    def run(argv)
      case argv.shift
      when "secret" then cmd_secret(argv)
      when "database-url" then cmd_database_url(argv)
      when "env" then cmd_env(argv)
      when "init" then cmd_init(argv)
      when "doctor" then cmd_doctor(argv)
      when "release-embeddings" then cmd_release_embeddings(argv)
      when "release-runtime" then cmd_release_runtime(argv)
      when nil, "help", "-h", "--help" then cmd_help
      else
        warn "Unknown command: #{argv.first.inspect}"
        cmd_help
        exit 1
      end
    end

    # bin/house secret NAME [FILE]
    #
    # Env-first, file-fallback resolver used by .kamal/secrets so a fork can
    # supply RAILS_MASTER_KEY and friends either as real environment
    # variables or as the key files this repo has always used.
    def cmd_secret(argv)
      name, file = argv
      abort "Usage: bin/house secret NAME [FILE]" unless name

      puts resolve_secret(name, file)
    end

    # bin/house database-url
    #
    # Prints DATABASE_URL if it's already set, otherwise composes it from
    # POSTGRES_PASSWORD. Exists as a subcommand, rather than a `||` inside
    # .kamal/secrets, because Kamal's dotenv command substitution only
    # replaces the $(...) span it matches — a trailing `|| echo ...` outside
    # the parens is left as literal text, not evaluated as shell logic.
    def cmd_database_url(_argv)
      url = ENV["DATABASE_URL"]
      if url && !url.empty?
        puts url
        return
      end

      password = resolve_secret("POSTGRES_PASSWORD", "config/credentials/deployment/postgres_pw_prod.key")
      puts "postgres://souls_house:#{password}@souls-house-postgres:5432/souls_house_production"
    end

    # bin/house env — prints the HOUSE_* configuration this checkout would
    # deploy with. These name an installation, not a credential, so they're
    # printed plainly (unlike bin/house secret).
    def cmd_env(_argv)
      HOUSE_KEYS.each { |key| puts "#{key}=#{ENV[key]}" }
    end

    # bin/house init [--from FILE] [--yes] [--force]
    #
    # Creates config/house.env from config/house.env.example — interactively
    # by default, from an answers file with --from, or accepting every
    # default with --yes. See House::Init.
    def cmd_init(argv)
      options = { from: nil, yes: false, force: false }
      until argv.empty?
        case (arg = argv.shift)
        when "--yes" then options[:yes] = true
        when "--force" then options[:force] = true
        when "--from"
          options[:from] = argv.shift or abort("Usage: bin/house init [--from FILE] [--yes] [--force]")
        else
          abort "Unknown option: #{arg}"
        end
      end

      exit(House::Init.new(root: House::ROOT, **options).run ? 0 : 1)
    end

    # bin/house doctor
    #
    # Checks this checkout's config/house.env against the host it names —
    # required keys, the embeddings digest, DNS, the host itself over a
    # read-only SSH probe, and every secret .kamal/secrets will need. See
    # House::Doctor.
    def cmd_doctor(_argv)
      exit House::Doctor.new(root: House::ROOT, env: ENV).run
    end

    # bin/house release-embeddings [--dry-run]
    #
    # Builds and publishes services/mnemodyne-embeddings, then records its
    # manifest digest in config/house.env. See House::ReleaseEmbeddings.
    def cmd_release_embeddings(argv)
      dry_run = !!argv.delete("--dry-run")
      exit(House::ReleaseEmbeddings.new(root: House::ROOT, env: ENV, dry_run: dry_run).run ? 0 : 1)
    rescue => e
      warn e.message
      exit 1
    end

    # bin/house release-runtime [SHA_TAG] [--dry-run]
    #
    # Thin wrapper around scripts/build-agent-runtime, which already reads
    # config/house.env itself once this process has loaded it.
    def cmd_release_runtime(argv)
      dry_run = !!argv.delete("--dry-run")
      sha_tag = argv.shift

      cmd = [File.join(House::ROOT, "scripts/build-agent-runtime")]
      cmd << sha_tag if sha_tag

      docker_host = [ENV["HELIXKIT_AGENT_RUNTIME_DOCKER_HOST"], ENV["HOUSE_AGENT_RUNTIME_DOCKER_HOST"]].find { |v| v && !v.strip.empty? }
      if docker_host.nil? && ENV["HOUSE_SSH_USER"] && ENV["HOUSE_HOST"] && ENV["HOUSE_SSH_PORT"]
        docker_host = "ssh://#{ENV['HOUSE_SSH_USER']}@#{ENV['HOUSE_HOST']}:#{ENV['HOUSE_SSH_PORT']}"
      end

      if dry_run
        puts "Docker host: #{docker_host || '(none configured)'}"
        puts "Command: #{cmd.join(' ')}"
        return
      end

      Kernel.exec(*cmd)
    end

    def cmd_help
      puts <<~USAGE
        Usage: bin/house COMMAND

          secret NAME [FILE]        Env-first, file-fallback secret resolver
          database-url               Compose DATABASE_URL from POSTGRES_PASSWORD
          env                        Print this checkout's HOUSE_* configuration
          init [--from FILE] [--yes] [--force]
                                      Create config/house.env from the example
          doctor                     Check config/house.env against the host it names
          release-embeddings [--dry-run]
                                      Build, publish, and record the embeddings image digest
          release-runtime [SHA_TAG] [--dry-run]
                                      Build the hosted-agent runtime image

        See docs/2026-09-07-forkable-house-plan-from-lume.md.
      USAGE
    end

    private

    def resolve_secret(name, file)
      value = ENV[name]
      return value if value && !value.empty?

      file = File.expand_path(file, House::ROOT) if file
      return File.read(file).strip if file && File.exist?(file)

      location = file ? "create #{file}" : "create a secret file"
      abort "Secret #{name} not found: set it in the environment or #{location}"
    end
  end
end
