ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Select locked gems before local-instance helpers load JSON.

require_relative "local_instance"
LocalInstance.current.claim!

require "bootsnap/setup" # Speed up boot time by caching expensive operations.
