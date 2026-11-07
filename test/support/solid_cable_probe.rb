# Standalone child process, never loads this application's Rails environment.
require "json"
require "logger"
require "rails"
require "rails/engine"
require "active_support/all"
require "active_record"
require "active_job"
require "action_cable"
require "solid_cable"

$stdout.sync = true
schema = ENV.fetch("CABLE_PROBE_SCHEMA")
abort "Not a synthetic Cable schema" unless schema.match?(/\Acable_probe_[0-9a-f]{24}\z/)
host = ENV.fetch("PGHOST")
abort "Not a local test PostgreSQL server" unless host.start_with?("/") || %w[localhost 127.0.0.1 postgres].include?(host)

Rails.application = Struct.new(:executor, :error_reporter).new(ActiveSupport::Executor, ActiveSupport::ErrorReporter.new)
Rails.error.subscribe(Object.new.tap do |reporter|
  def reporter.report(error, **)
    puts JSON.generate(event: "error", type: error.class.name)
  end
end)
ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "postgres",
  host: host, port: ENV["PGPORT"], username: ENV["PGUSER"] || ENV.fetch("USER"),
  password: ENV["PGPASSWORD"], schema_search_path: schema, pool: 5,
  variables: { application_name: "#{schema}_#{ARGV.fetch(0)}" })
SolidCable.configure(polling_interval: "0.01.seconds", message_retention: "1.day",
  autotrim: false, writer_batch_delay: ARGV.include?("delayed") ? "5.seconds" : "0.001.seconds")
gem_root = Gem.loaded_specs.fetch("solid_cable").full_gem_path
require File.join(gem_root, "app/models/solid_cable/record")
# Normally Zeitwerk opens this model before loading its nested concern.
class SolidCable::Message < SolidCable::Record
end
require File.join(gem_root, "app/models/solid_cable/message/encryption")
require File.join(gem_root, "app/models/solid_cable/message")
require File.join(gem_root, "app/jobs/solid_cable/trim_job")

role = ARGV.fetch(0)
if role == "schema"
  ActiveRecord::Schema.verbose = false
  load File.expand_path("../../db/cable_schema.rb", __dir__)
  SolidCable::Message.create!(channel: "probe", channel_hash: SolidCable::Message.channel_hash_for("probe"),
    payload: "expired", created_at: 2.days.ago)
  puts JSON.generate(event: "schema")
  exit
elsif role == "trim"
  before = SolidCable::Message.count
  SolidCable::TrimJob.perform_now
  puts JSON.generate(event: "trim", before: before, after: SolidCable::Message.count)
  exit
end

server = ActionCable::Server::Base.new
server.config.cable = { adapter: "solid_cable" }
server.config.logger = Logger.new(File::NULL)
adapter = ActionCable::SubscriptionAdapter::SolidCable.new(server)
callback = ->(payload) { puts JSON.generate(event: "message", payload: payload) }
ready = -> { puts JSON.generate(event: "ready") }
adapter.subscribe("probe", callback, ready) if role == "subscriber"

begin
  $stdin.each_line do |line|
    command = JSON.parse(line)
    case command.fetch("command")
    when "broadcast"
      adapter.broadcast("probe", command.fetch("payload"))
      puts JSON.generate(event: "accepted")
    when "unsubscribe"
      adapter.unsubscribe("probe", callback)
      puts JSON.generate(event: "unsubscribed")
    when "subscribe"
      adapter.subscribe("probe", callback, ready)
    when "reconnect"
      adapter.shutdown
      adapter = ActionCable::SubscriptionAdapter::SolidCable.new(server)
      adapter.subscribe("probe", callback, ready)
    when "shutdown"
      adapter.shutdown
      puts JSON.generate(event: "flushed")
      break
    else
      abort "Unknown probe command"
    end
  end
ensure
  adapter.shutdown
  server.event_loop.stop
end
