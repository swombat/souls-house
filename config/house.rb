# frozen_string_literal: true

# House — the identity layer that turns this checkout into a specific
# installation. See config/house.env.example and
# docs/2026-09-07-forkable-house-plan-from-lume.md.
#
# Deliberately dependency-free (no Rails, no dotenv gem): both bin/kamal and
# bin/house need to load config/house.env before Bundler has necessarily
# been set up.
module House
  ROOT = File.expand_path("..", __dir__)

  class << self
    # Path to the (gitignored) file holding this installation's identity.
    def env_path
      File.join(ROOT, "config/house.env")
    end

    # Parses KEY=value lines, ignoring blank lines and comments, and
    # stripping one layer of optional surrounding quotes. Deliberately not a
    # full dotenv parser: house.env has no interpolation, no command
    # substitution, no export keyword.
    def parse(text)
      text.each_line.each_with_object({}) do |line, env|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        key, value = line.split("=", 2)
        next unless key && value

        env[key.strip] = unquote(value.strip)
      end
    end

    # Loads config/house.env into ENV, without overriding anything already
    # set — a real shell export always wins over the file. Safe to call when
    # the file doesn't exist: it's a no-op, which is what lets upstream's
    # actual house.env and a fork's differ without either needing a code
    # change.
    def load_env!
      return unless File.exist?(env_path)

      parse(File.read(env_path)).each { |key, value| ENV[key] ||= value }
    end

    private

    def unquote(value)
      if value.length >= 2 && (value.start_with?('"') && value.end_with?('"') ||
                                value.start_with?("'") && value.end_with?("'"))
        value[1..-2]
      else
        value
      end
    end
  end
end
