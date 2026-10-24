# frozen_string_literal: true

# Refuses to run Vite unless the project's own Vite is installed.
#
# vite_ruby runs `bun x --bun vite`. With node_modules installed that resolves
# to node_modules/.bin/vite. Without it, bun falls through to whatever `vite`
# is on PATH, and in a gem-installed toolchain that is vite_ruby's own `vite`
# executable, which runs `bun x --bun vite` again. Each copy waits on the next:
# on 10 Oct 2026 this reached 177 copies, held a resident container at its
# memory limit for three hours and OOM-killed every run that started there.
#
# Pinning `viteBinPath` would not stop it: vite_ruby only uses the pinned path
# when the file exists and otherwise falls back to `bun x` silently, which is
# the failing case. So the guard sits on ViteRuby::Runner#run, the one place
# every build (bin/vite build, bin/vite dev, Rails auto-build, assets:precompile)
# passes through before a process is spawned, and raises instead.
module ViteGuard
  BIN = File.join("node_modules", ".bin", "vite")

  class MissingViteError < StandardError; end

  module_function

  def check!(root)
    path = File.join(root.to_s, BIN)
    return if File.executable?(path)

    raise MissingViteError, "#{path} is missing. Run `bun install` in #{root} first. " \
      "Refusing to run Vite: without it `bun x vite` can resolve to the vite_ruby gem executable, " \
      "which calls `bun x vite` again and forks until the container runs out of memory."
  end

  def install!
    require "vite_ruby"
    ViteRuby::Runner.prepend(RunnerGuard) unless ViteRuby::Runner <= RunnerGuard
  end

  module RunnerGuard
    def run(argv, **options)
      ViteGuard.check!(config.root)
      super
    end
  end
end
