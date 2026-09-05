# frozen_string_literal: true

require "fiddle/import"

module LocalInstance
  # Ruby exposes process groups but not POSIX foreground-terminal ownership.
  # Keep the native boundary limited to these two libc calls (macOS/Linux).
  module Terminal

    extend Fiddle::Importer
    dlload Fiddle::Handle::DEFAULT
    extern "int tcgetpgrp(int)"
    extern "int tcsetpgrp(int, int)"

  end
end
