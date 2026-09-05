#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../config/local_instance"
require "net/http"
require "securerandom"

# Invoked under bin/instance's shared test lock, with RAILS_ENV=test.
config = LocalInstance.current
abort "Test backend requires RAILS_ENV=test" unless config.environment == "test"
config.configure!
mode = ARGV.shift || "e2e"
abort "Unknown test mode" unless %w[e2e ct server].include?(mode)
Dir.chdir(config.root)
FileUtils.mkdir_p("log")
FileUtils.mkdir_p("tmp/pids")
log = "log/playwright-#{mode}.log"
pidfile = File.join(config.root, "tmp/pids/playwright.pid")
uri = URI("http://127.0.0.1:#{config.port(:backend)}/up")
child = nil
server_token = SecureRandom.hex(24)
begin
  system("bin/rails", "db:prepare", exception: true)
  system("bin/rails", "db:fixtures:load", exception: true) if mode != "e2e"
  system("bin/vite", "build", "--mode", "test", "--force", exception: true)
  child = Process.spawn({ "PIDFILE" => pidfile, "SOULSHOUSE_SERVER_TOKEN" => server_token }, "bin/rails", "server", "-e", "test", "-p", config.port(:backend).to_s,
    "-b", "127.0.0.1", out: log, err: [ :child, :out ])
  ready = false
  60.times do
    if Process.waitpid(child, Process::WNOHANG)
      child = nil
      raise "Rails child exited; see #{log}"
    end
    begin
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 2) { |http| http.get(uri.path) }
      if response.code == "200" && response["x-souls-house-instance"] == config.fingerprint && response["x-souls-house-server"] == server_token
        # Check the child again: an existing server must not impersonate startup.
        if Process.waitpid(child, Process::WNOHANG)
      child = nil
      raise "Rails child exited; see #{log}"
        end
        ready = true
        break
      end
    rescue SystemCallError, Timeout::Error, EOFError
      # Retry only while our child remains alive.
    end
    sleep 1
  end
  raise "Owned Rails backend did not become ready; see #{log}" unless ready
  puts "Instance #{config.number} test backend ready at #{uri}"
  if mode == "server"
    Process.wait(child)
    exit($?.exitstatus || 1)
  end
  cli = mode == "e2e" ? "node_modules/@playwright/test/cli.js" : "node_modules/@playwright/experimental-ct-svelte/cli.js"
  success = system("node", cli, "test", "-c", "playwright-#{mode}.config.js", *ARGV)
  exit(success ? 0 : 1)
ensure
  if child
    begin
      Process.kill("TERM", child)
      Timeout.timeout(10) { Process.wait(child) }
    rescue Errno::ESRCH, Errno::ECHILD
      # Already exited/reaped.
    rescue Timeout::Error
      Process.kill("KILL", child) rescue Errno::ESRCH
      Process.wait(child) rescue Errno::ECHILD
    end
  end
end
