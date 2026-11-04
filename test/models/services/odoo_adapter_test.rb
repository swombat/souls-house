require "test_helper"
require "webmock/minitest"

class Services::OdooAdapterTest < ActiveSupport::TestCase

  API = "https://erp.example.com/jsonrpc".freeze
  KEY = "SyntheticCaseSensitiveKEY".freeze

  setup do
    @adapter = Services::OdooAdapter.new(Services::Definition.fetch("odoo"))
    @credentials = { "api_url" => "https://erp.example.com/", "database" => "books", "login" => "reader", "api_key" => KEY }
  end

  def public_dns(&)
    @adapter.stub(:resolve_addresses, ->(_) { [ "93.184.216.34" ] }, &)
  end

  def connect
    public_dns { @adapter.connection_attributes(credentials: @credentials, user: users(:user_1)) }
  end

  def stub_rpc(method, result:, status: 200)
    stub_request(:post, API).with { |request| JSON.parse(request.body).dig("params", "method") == method }
      .to_return(status: status, body: { jsonrpc: "2.0", id: 1, result: result }.to_json)
  end

  def stub_version(major = 18)
    stub_rpc("version", result: { server_version_info: [ major, 0, 0, "final", 0, "e" ] })
  end

  test "validates version and authentication and keeps opaque key only in payload" do
    version = stub_version
    auth = stub_rpc("authenticate", result: 7)
    result = connect

    assert_requested version
    assert_requested auth
    assert_equal({ "api_key" => KEY }, result[:credential_payload])
    assert_equal "https://erp.example.com|books|7", result[:external_subject_id]
    assert_equal 7, result.dig(:credential_metadata, "uid")
    assert_equal "18.0.0", result.dig(:credential_metadata, "odoo_version")
    assert_equal "not checked", result.dig(:credential_metadata, "odoo_edition")
    assert_match "full permissions", result.dig(:credential_metadata, "authority_summary")
    assert_not_includes result[:credential_metadata].to_json, KEY
    assert_not_includes result[:credential_fingerprint], KEY
    assert_equal true, @adapter.revoke(nil)
    assert_requested :post, API, body: {
      jsonrpc: "2.0", method: "call", id: 1,
      params: { service: "common", method: "authenticate", args: [ "books", "reader", KEY, {} ] }
    }.to_json
  end

  test "supported numbered versions validate while older and future versions refuse" do
    [ 16, 17, 18, 19 ].each do |major|
      stub_version(major)
      stub_rpc("authenticate", result: 7)
      assert_equal "#{major}.0.0", connect.dig(:credential_metadata, "odoo_version")
    end
    [ 15, 20 ].each do |major|
      stub_version(major)
      assert_match "16–19", assert_raises(Services::OdooAdapter::Error) { connect }.message
    end
  end

  test "SaaS versions preserve their branch and point release in metadata" do
    [ 16, 17, 18, 19 ].each do |major|
      stub_rpc("version", result: { server_version_info: [ "saas~#{major}", 4, 0, "final", 0, "e" ] })
      stub_rpc("authenticate", result: 7)
      assert_equal "saas~#{major}.4.0", connect.dig(:credential_metadata, "odoo_version")
    end
  end

  test "malformed and unsupported version information refuses before authentication" do
    [ nil, false, {}, [], [ 19 ], [ 19, 0 ], [ "19", 0, 0 ],
      [ "saas~15", 4, 0 ], [ "saas~20", 1, 0 ], [ "saas~19.4", 0, 0 ],
      [ "saas~019", 4, 0 ], [ "saas~19\n", 4, 0 ], [ true, 0, 0 ],
      [ 19, "4", 0 ], [ 19, -1, 0 ], [ "saas~19", 4, false ] ].each do |info|
      stub_rpc("version", result: { server_version_info: info })
      assert_raises(Services::OdooAdapter::Error) { connect }
    end
    assert_not_requested :post, API, body: /authenticate/
  end

  test "refused and wrongly shaped uids are not authenticated" do
    stub_version
    [ false, nil, true, "7", 0, -1, {} ].each do |uid|
      stub_rpc("authenticate", result: uid)
      assert_match "rejected", assert_raises(Services::OdooAdapter::Error) { connect }.message
    end
  end

  test "missing required credentials and bad URLs are rejected without network" do
    [ "http://erp.example.com", "https://user:secret@erp.example.com",
      "https://erp.example.com?key=secret", "https://erp.example.com#secret",
      "https://erp.example.com/a/../b", "https://erp.example.com/%2e%2e" ].each do |url|
      assert_raises(Services::OdooAdapter::Error) { Services::OdooAdapter.normalize_api_url(url) }
    end
    %w[database login api_key].each do |field|
      credentials = @credentials.merge(field => "")
      assert_raises(Services::OdooAdapter::Error) { @adapter.connection_attributes(credentials: credentials, user: nil) }
    end
    assert_not_requested :any, /example\.com/
  end

  test "private mixed documentation and mapped addresses are refused before key transmission" do
    %w[127.0.0.1 10.1.2.3 100.101.102.103 169.254.169.254 192.0.2.1 198.18.0.1
       ::1 ::ffff:192.168.1.1 fd00::1 fe80::1 2001:db8::1 2002:7f00:1::1].each do |address|
      @adapter.stub(:resolve_addresses, ->(_) { [ "93.184.216.34", address ] }) do
        assert_raises(Services::OdooAdapter::Error) { @adapter.connection_attributes(credentials: @credentials, user: nil) }
      end
    end
    @adapter.stub(:resolve_addresses, ->(_) { [] }) do
      assert_raises(Services::OdooAdapter::Error) { @adapter.connection_attributes(credentials: @credentials, user: nil) }
    end
    assert_not_requested :any, /example\.com/
  end

  test "pins checked address disables proxies and retries and verifies TLS" do
    stub_version
    stub_rpc("authenticate", result: 7)
    original = Net::HTTP.method(:new)
    clients = []
    Net::HTTP.stub(:new, ->(*args) {
      assert_nil args[2]
      original.call(*args).tap { |client| clients << client }
    }) { connect }
    assert_equal 2, clients.size
    clients.each do |client|
      assert_equal "93.184.216.34", client.ipaddr
      assert_equal "erp.example.com", client.address
      assert_equal 0, client.max_retries
      assert client.use_ssl?
    end
  end

  test "redirects and HTTP errors are not followed and never echo provider bodies" do
    [ 301, 302, 401, 403, 404, 500 ].each do |status|
      stub_request(:post, API).to_return(status: status, body: KEY, headers: { "Location" => "https://elsewhere.example/" })
      error = assert_raises(Services::OdooAdapter::Error) { connect }
      assert_not_includes error.message, KEY
    end
    assert_not_requested :any, /elsewhere/
  end

  test "unreachable and TLS failures are secret-safe" do
    [ SocketError.new(KEY), Net::OpenTimeout.new(KEY), Net::ReadTimeout.new(KEY),
      OpenSSL::SSL::SSLError.new(KEY) ].each do |failure|
      stub_request(:post, API).to_raise(failure)
      error = assert_raises(Services::OdooAdapter::Error) { connect }
      assert_equal "Could not reach Odoo over https", error.message
    end
  end

  test "malformed RPC error oversized and non-JSON responses refuse without provider details" do
    [ KEY, "[]", "null", { jsonrpc: "2.0", id: 1, error: { data: { debug: KEY } } }.to_json,
      { jsonrpc: "2.0", id: 2, result: {} }.to_json, "x" * 1_048_577 ].each do |body|
      stub_request(:post, API).to_return(status: 200, body: body)
      error = assert_raises(Services::OdooAdapter::Error) { connect }
      assert_not_includes error.message, KEY
    end
  end

  test "opaque key fingerprint is case sensitive" do
    assert_not_equal @adapter.send(:credential_fingerprint, KEY), @adapter.send(:credential_fingerprint, KEY.downcase)
  end

end
