require "minitest/autorun"
require "active_support"
require "active_support/core_ext/object/blank"
require "action_dispatch"
require "action_controller/railtie"
require "rails/health_controller"
require_relative "../../config/stone_hosting"

# Exercise the first middleware without booting Rails or touching a database.
class StoneBoundaryTest < Minitest::Test

  def setup
    @previous = %w[SOULSHOUSE_STONES_ONLY SOULSHOUSE_STONES_DOMAIN].to_h { |key| [ key, ENV[key] ] }
    ENV["SOULSHOUSE_STONES_ONLY"] = "1"
    ENV["SOULSHOUSE_STONES_DOMAIN"] = "soulstones.test"
    @calls = []
    @boundary = StoneHosting::Boundary.new(lambda do |env|
      @calls << env.dup
      [ 200, { "set-cookie" => "lower=1", "Set-Cookie" => "upper=1" }, [ "Downstream" ] ]
    end)
  end

  def teardown
    @previous.each { |key, value| ENV[key] = value }
  end

  def test_stones_only_rejects_non_stone_hosts_before_downstream
    [ "house.test", "localhost", "127.0.0.1:3000", "[::1]:3000", "evil-soulstones.test" ].each do |host|
      [ "/", "/login", "/api/v1/conversations", "/cable", "/assets/app.js", "/favicon.ico",
        "/revisions/1/content" ].each do |path|
        assert_denied path, host: host
      end
    end
    assert_empty @calls
  end

  def test_missing_or_blank_domain_does_not_disable_stones_only_guard
    [ nil, "", "  " ].each do |domain|
      ENV["SOULSHOUSE_STONES_DOMAIN"] = domain
      [ "house.test", "quiet-blue-river.soulstones.test" ].each do |host|
        assert_denied "/", host: host
        assert_denied "/api/v1/conversations", host: host
      end
    end
    assert_empty @calls
  end

  def test_web_requests_keep_credentials_cookies_and_routes
    [ nil, "0" ].each do |mode|
      ENV["SOULSHOUSE_STONES_ONLY"] = mode
      [ "soulstones.test", nil ].each do |domain|
        ENV["SOULSHOUSE_STONES_DOMAIN"] = domain
        [ "/", "/login", "/api/v1/conversations", "/assets/app.js", "/up" ].each do |path|
          status, headers, = call_boundary(path)
          assert_equal 200, status
          assert_equal "lower=1", headers["set-cookie"]
          assert_equal "session=synthetic", @calls.last["HTTP_COOKIE"]
          assert_equal "Bearer synthetic", @calls.last["HTTP_AUTHORIZATION"]
        end
      end
    end
  end

  def test_stone_documents_retain_allowlist_and_credential_isolation_in_both_modes
    [ nil, "1" ].each do |mode|
      ENV["SOULSHOUSE_STONES_ONLY"] = mode
      [ "GET", "HEAD" ].each do |method|
        [ "/", "/revisions/1", "/revisions/2/content" ].each do |path|
          status, headers, = call_boundary(path, method: method,
            host: "quiet-blue-river.soulstones.test.",
            forwarded: "house.test")
          assert_equal 200, status
          refute headers.key?("set-cookie")
          refute headers.key?("Set-Cookie")
          env = @calls.last
          assert_equal "quiet-blue-river", env["souls_house.stone_name"]
          assert_equal "quiet-blue-river.soulstones.test", env["HTTP_HOST"]
          %w[HTTP_COOKIE HTTP_AUTHORIZATION HTTP_X_FORWARDED_HOST HTTP_FORWARDED].each do |key|
            refute env.key?(key), key
          end
        end
      end
      [ "/login", "/api/v1/conversations", "/up", "/revisions/0/content", "/assets/app.js" ].each do |path|
        assert_denied path, host: "quiet-blue-river.soulstones.test"
      end
      assert_denied "/", method: "POST", host: "quiet-blue-river.soulstones.test"
      assert_denied "/", host: "soulstones.test"
      assert_denied "/", host: "unknown.soulstones.test"
      assert_denied "/login", forwarded: "quiet-blue-river.soulstones.test"
    end
  end

  def test_only_exact_read_only_health_path_can_reach_downstream_on_internal_hosts
    [ "soulstones.test", nil ].each do |domain|
      ENV["SOULSHOUSE_STONES_DOMAIN"] = domain
      [ "GET", "HEAD" ].each do |method|
        assert_equal 200, call_boundary("/up", method: method, host: "172.18.0.2:3000").first
      end
      [ "POST", "PUT", "PATCH", "DELETE", "OPTIONS" ].each do |method|
        assert_denied "/up", method: method
      end
      [ "/up/", "/up.json", "/up/login", "/UP", "/%75p" ].each do |path|
        assert_denied path
      end
    end
    assert_equal 4, @calls.size
  end

  def test_only_a_small_json_post_to_a_revisions_rows_path_is_let_through
    host = "quiet-blue-river.soulstones.test"
    body = '{"table":"Posts","row":{"platform":"x"}}'
    status, headers, = call_boundary("/revisions/2/rows", method: "POST", host: host, body: body)
    assert_equal 200, status
    refute headers.key?("set-cookie")
    env = @calls.last
    assert_equal "quiet-blue-river", env["souls_house.stone_name"]
    assert_nil env["HTTP_COOKIE"]
    assert_nil env["HTTP_AUTHORIZATION"]

    assert_denied "/revisions/2/rows", method: "POST", host: host, body: body, content_type: "text/plain"
    assert_denied "/revisions/2/rows", method: "POST", host: host, body: body, content_type: "application/x-www-form-urlencoded"
    assert_denied "/revisions/2/rows", method: "POST", host: host, body: ""
    assert_denied "/revisions/2/rows", method: "POST", host: host, body: "x" * 20_000
    assert_denied "/revisions/2/rows", method: "PUT", host: host, body: body
    assert_denied "/revisions/2/rows", host: host
    assert_denied "/revisions/0/rows", method: "POST", host: host, body: body
    assert_denied "/revisions/2/data", method: "POST", host: host, body: body
    assert_denied "/revisions/2/rows/1", method: "POST", host: host, body: body
    assert_denied "/revisions/2/rows", method: "POST", host: "soulstones.test", body: body
  end

  def test_internal_health_check_reaches_real_rails_health_controller
    @boundary = StoneHosting::Boundary.new(Rails::HealthController.action(:show))
    [ "soulstones.test", nil ].each do |domain|
      ENV["SOULSHOUSE_STONES_DOMAIN"] = domain
      %w[GET HEAD].each do |method|
        status, headers, body = call_boundary("/up", method: method, host: "172.18.0.2:3000")
        assert_equal 200, status
        refute headers.key?("set-cookie")
        body.close if body.respond_to?(:close)
      end
    end
  end

  private

  def assert_denied(path, **options)
    before = @calls.size
    status, headers, = call_boundary(path, **options)
    assert_equal 404, status, "#{options} #{path}"
    assert_equal "no-store", headers["cache-control"]
    refute headers.key?("set-cookie")
    assert_equal before, @calls.size, "denied request reached downstream"
  end

  def call_boundary(path, host: "house.test", method: "GET", forwarded: nil, body: nil, content_type: "application/json")
    options = { method: method }
    options.merge!(input: body, "CONTENT_TYPE" => content_type) if body
    env = Rack::MockRequest.env_for("http://#{host}#{path}", options)
    env["HTTP_HOST"] = host
    env["HTTP_COOKIE"] = "session=synthetic"
    env["HTTP_AUTHORIZATION"] = "Bearer synthetic"
    env["HTTP_X_FORWARDED_HOST"] = forwarded if forwarded
    env["HTTP_FORWARDED"] = "host=house.test"
    @boundary.call(env)
  end

end
