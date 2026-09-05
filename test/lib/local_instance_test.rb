require "minitest/autorun"
require "tmpdir"
require_relative "../../config/local_instance"

class LocalInstanceTest < Minitest::Test

  def setup
    @directory = Dir.mktmpdir("souls-instance-test")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def config(name = "souls-house", env = {}, environment = "development")
    path = File.join(@directory, name)
    FileUtils.mkdir_p(path)
    LocalInstance::Configuration.new(root: path, env: env, environment: environment)
  end

  def test_known_names_and_explicit_override
    assert_equal 0, config.number
    assert_equal 2, config("souls-house-2").number
    assert_equal 3, config("anything", { "SOULSHOUSE_INSTANCE" => "3" }).number
    assert_raises(LocalInstance::Error) { config("anything").number }
    %w[-1 10 01 abc].each do |value|
      assert_raises(LocalInstance::Error) { config("souls-house", { "SOULSHOUSE_INSTANCE" => value }).number }
    end
  end

  def test_ports_and_worker_databases_never_overlap
    configurations = (0..9).map { |number| config("souls-house-#{number}") }
    ports = configurations.flat_map { |c| LocalInstance::PORTS.keys.map { |key| c.port(key) } }
    assert_equal ports.length, ports.uniq.length
    databases = configurations.flat_map do |c|
      %i[primary cache queue cable].map { |role| c.database("development", role) } +
        [ c.database("test") ] + (0..15).map { |worker| "#{c.database('test')}-#{worker}" }
    end
    assert_equal databases.length, databases.uniq.length
    assert_equal "helix_kit_development", configurations.first.database("development")
  end

  def test_foreign_urls_fail_without_disclosing_secrets
    %w[DATABASE_URL PRIMARY_DATABASE_URL CACHE_DATABASE_URL].each do |key|
      error = assert_raises(LocalInstance::Error) { config("souls-house-1", { key => "postgres://secret" }).validate! }
      refute_includes error.message, "secret"
    end
  end

  def test_claims_are_idempotent_and_reject_duplicate_checkouts
    registry = File.join(@directory, "registry")
    first = config("souls-house-1")
    2.times { first.claim!(directory: registry) }
    other = config("another", { "SOULSHOUSE_INSTANCE" => "1" })
    assert_raises(LocalInstance::Error) { other.claim!(directory: registry) }
  end

  def test_cookies_and_docker_are_isolated_by_instance_and_environment
    first = config("souls-house-1")
    second = config("souls-house-2")
    test = config("souls-house-1", {}, "test")
    assert_equal 3, [ first, second, test ].map { |c| c.cookie("session_id") }.uniq.length
    assert_equal 3, [ first, second, test ].map(&:namespace).uniq.length
    assert_nil config.namespace
    assert_equal "session_id", config.cookie("session_id")
  end

  def test_production_ignores_instance_and_local_safety_rules
    production = config("app", { "SOULSHOUSE_INSTANCE" => "invalid", "DATABASE_URL" => "postgres://secret" }, "production")
    production.validate!
    production.configure!
    assert_nil production.namespace
    assert_equal "session_id", production.cookie("session_id")
    assert_equal "helix_kit_development", production.database("development")
  end

end
