# frozen_string_literal: true

require "json"
require "open3"

module LocalInstance
  module Toolchain

    module_function

    def ruby!(root)
      expected = File.read(File.join(root, ".ruby-version")).strip
      raise Error, "Use Ruby #{expected}; review mise.toml, then mise trust && mise install && mise exec -- <command>." unless RUBY_VERSION == expected
    end

    def bun!(root)
      expected = JSON.parse(File.read(File.join(root, "package.json"))).fetch("packageManager").delete_prefix("bun@")
      version, _, status = Open3.capture3("bun", "--version")
      return if status.success? && version.strip == expected
      raise Error, "Use Bun #{expected} for setup/frontend commands; run mise install && mise exec -- <command>."
    rescue Errno::ENOENT
      raise Error, "Bun is required for setup/frontend commands; run mise install && mise exec -- <command>."
    end

  end
end
