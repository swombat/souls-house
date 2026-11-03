require "minitest/autorun"
require "erb"

class WebThreadDefaultsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_threads_and_database_pool_default_to_thirty
    assert_capacity(nil, 30)
  end

  def test_explicit_thread_override_also_sets_database_pool
    assert_capacity("12", 12)
  end

  private

  def assert_capacity(override, expected)
    previous = ENV["RAILS_MAX_THREADS"]
    ENV["RAILS_MAX_THREADS"] = override
    config = Object.new
    config.define_singleton_method(:threads) { |min, max| @threads = [min.to_i, max.to_i] }
    config.define_singleton_method(:port) { |*| }
    config.define_singleton_method(:plugin) { |*| }
    config.define_singleton_method(:pidfile) { |*| }
    config.instance_eval(File.read(File.join(ROOT, "config/puma.rb")))
    assert_equal [expected, expected], config.instance_variable_get(:@threads)

    pool = File.read(File.join(ROOT, "config/database.yml")).lines.find { |line| line.match?(/^\s+pool:/) }
    assert_equal expected, ERB.new(pool).result.split(":").last.to_i
  ensure
    ENV["RAILS_MAX_THREADS"] = previous
  end
end
