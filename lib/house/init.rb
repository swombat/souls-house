# frozen_string_literal: true

require "ipaddr"
require_relative "../../config/house"
require_relative "env_file"

module House
  # bin/house init — creates config/house.env from config/house.env.example,
  # either interactively, from a KEY=value answers file, or by accepting
  # every default.
  class Init

    def initialize(root:, from: nil, yes: false, force: false, stdin: $stdin, out: $stdout)
      @root = root
      @from = from
      @yes = yes
      @force = force
      @stdin = stdin
      @out = out
    end

    # Returns true on success, false if it refused to run (an existing
    # config/house.env without --force). Aborts (raising SystemExit) on a
    # missing example file or an invalid value.
    def run
      example_path = File.join(@root, "config/house.env.example")
      abort "Missing #{example_path}" unless File.exist?(example_path)

      if File.exist?(house_env_path) && !@force
        @out.puts "#{house_env_path} already exists; pass --force to overwrite."
        return false
      end

      example_text = File.read(example_path)
      answers = @from ? House.parse(File.read(@from)) : {}

      values = {}
      House::EnvFile.entries(example_text).each do |entry|
        key = entry[:key]
        # --from is non-interactive: a key the answers file doesn't mention
        # keeps its default, same as --yes, rather than prompting for it.
        value = if answers.key?(key)
          answers[key]
        elsif @yes || @from
          entry[:default]
        else
          prompt(entry)
        end

        error = validate(key, value)
        abort "#{key}: #{error} (got #{value.inspect})" if error

        values[key] = value
      end

      text = values.reduce(example_text) { |acc, (key, value)| House::EnvFile.set_value(acc, key, value) }
      File.write(house_env_path, text)
      @out.puts "Wrote #{house_env_path}"

      offer_fresh_credentials
    end

    private

    def house_env_path
      File.join(@root, "config/house.env")
    end

    def prompt(entry)
      entry[:comments].each { |line| @out.print line }
      default = entry[:default]
      loop do
        @out.print "#{entry[:key]} [#{default}]: "
        line = @stdin.gets
        return default if line.nil?

        line = line.strip
        value = line.empty? ? default : line

        error = validate(entry[:key], value)
        if error
          @out.puts "  #{error}"
          next
        end

        return value
      end
    end

    def validate(key, value)
      value = value.to_s
      case key
      when "HOUSE_DOMAIN"
        "doesn't look like a hostname" unless hostname?(value)
      when "HOUSE_HOST"
        "must be an IP address or a hostname" unless ip?(value) || hostname?(value)
      when "HOUSE_SSH_PORT"
        "must be an integer" unless value.match?(/\A\d+\z/)
      when "HOUSE_STORAGE"
        "must be \"s3\" or \"local\"" unless %w[s3 local].include?(value)
      when "HOUSE_EMBEDDINGS_DIGEST"
        "must be blank or sha256:<64 hex characters>" unless value.empty? || value.match?(/\Asha256:[0-9a-f]{64}\z/)
      end
    end

    def ip?(value)
      IPAddr.new(value)
      true
    rescue IPAddr::Error, ArgumentError
      false
    end

    def hostname?(value)
      return false if value.empty?

      value.match?(/\A(?=.{1,253}\z)(?!-)[A-Za-z0-9-]{1,63}(?<!-)(\.(?!-)[A-Za-z0-9-]{1,63}(?<!-))*\z/)
    end

    # Only offer automatic replacement when this checkout has no production
    # key. An existing key may belong to a working installation.
    def offer_fresh_credentials
      template_path = File.join(@root, "config/credentials/production.example.yml")
      return true unless File.exist?(template_path)

      enc_path = File.join(@root, "config/credentials/production.yml.enc")
      key_path = File.join(@root, "config/credentials/production.key")
      if File.exist?(key_path) || !ENV["RAILS_MASTER_KEY"].to_s.empty?
        @out.puts "Production key already configured; leaving credentials untouched."
        return true
      end

      @out.puts <<~MSG

        Next: create fresh production credentials for this installation.
        No production key is configured. If the encrypted file belongs to
        an existing installation, recover its key instead of replacing it.
        Otherwise back up the existing production.yml.enc, move it aside,
        then run bin/rails credentials:edit --environment production.
        Paste config/credentials/production.example.yml into the editor,
        fill in real values, and keep the generated key private.
      MSG

      return true if @yes || @from

      editor = ENV["EDITOR"]
      if editor.nil? || editor.strip.empty?
        @out.puts "(EDITOR is not set; follow the steps above yourself when ready.)"
        return true
      end

      @out.print "Back up any existing ciphertext and create fresh production credentials now? [y/N] "
      answer = @stdin.gets
      return true unless answer&.strip&.downcase == "y"

      create_fresh_credentials(template_path, enc_path, key_path)
    end

    # Seed without booting production Rails (which needs these credentials).
    # Stage both files first; retain the previous ciphertext as a backup and
    # restore it if the editor fails. Never print credential contents.
    def create_fresh_credentials(template_path, enc_path, key_path)
      require "bundler/setup"
      require "active_support"
      require "active_support/encrypted_file"
      require "tmpdir"

      backup_path = "#{enc_path}.backup"
      if File.exist?(backup_path)
        @out.puts "Credentials backup already exists at #{backup_path}; resolve it before retrying."
        return false
      end

      installed = false
      success = false
      Dir.mktmpdir("house-credentials") do |dir|
        staged_key = File.join(dir, "production.key")
        staged_enc = File.join(dir, "production.yml.enc")
        File.write(staged_key, ActiveSupport::EncryptedFile.generate_key, mode: "wx", perm: 0o600)
        encrypted = ActiveSupport::EncryptedFile.new(
          content_path: staged_enc, key_path: staged_key,
          env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true
        )
        encrypted.write(File.read(template_path))
        File.rename(enc_path, backup_path) if File.exist?(enc_path)
        installed = true
        File.write(key_path, File.read(staged_key), mode: "wx", perm: 0o600)
        File.write(enc_path, File.read(staged_enc), mode: "wx", perm: 0o600)
        success = system(File.join(@root, "bin/rails"), "credentials:edit", "--environment", "production", chdir: @root)
      end
      @out.puts(success ? "Fresh credentials created. Store production.key securely." : "Credential editor failed; restored the previous state.")
      !!success
    rescue StandardError => error
      @out.puts "Could not create fresh credentials (#{error.class}); check your dependencies and editor."
      false
    ensure
      if installed && !success
        File.delete(enc_path) if File.exist?(enc_path)
        File.delete(key_path) if File.exist?(key_path)
        File.rename(backup_path, enc_path) if File.exist?(backup_path)
      end
    end

  end
end
