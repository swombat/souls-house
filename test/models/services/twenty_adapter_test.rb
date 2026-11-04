require "test_helper"
require "webmock/minitest"

class Services::TwentyAdapterTest < ActiveSupport::TestCase

  KEY = "twenty-synthetic-secret".freeze
  URL = "https://crm.example.com/rest/people?limit=1&depth=0&fields=id".freeze

  setup do
    @adapter = Services::Definition.fetch("twenty").adapter
  end

  def connect(key: KEY, url: "https://crm.example.com", addresses: [ "93.184.216.34" ])
    @adapter.stub(:resolve_addresses, ->(_host) { addresses }) do
      @adapter.connection_attributes(credentials: { "api_url" => url, "api_key" => key }, user: users(:user_1))
    end
  end

  def stub_people(body: { data: { people: [ { id: "person-1" } ] } }, status: 200)
    stub_request(:get, URL).with(headers: { "Authorization" => "Bearer #{KEY}" })
      .to_return(status: status, body: body.to_json)
  end

  test "validates with a bounded read and keeps secrets only in the payload" do
    request = stub_people
    attributes = connect(key: " #{KEY} ")

    assert_requested request, times: 1
    assert_equal "https://crm.example.com", attributes[:external_subject_id]
    assert_equal({ "api_key" => KEY }, attributes[:credential_payload])
    assert_equal "https://crm.example.com/rest", attributes.dig(:credential_metadata, "api_base")
    assert_equal "static", attributes.dig(:credential_metadata, "credential_strategy")
    assert_match "did not inspect the key's role", attributes.dig(:credential_metadata, "authority_summary")
    assert_not_includes attributes.except(:credential_payload).to_json, KEY
    assert_equal 64, attributes[:credential_fingerprint].length
    assert_equal attributes[:credential_fingerprint], connect[:credential_fingerprint]
    assert @adapter.revoke(nil)
  end

  test "an empty workspace is a valid authenticated response" do
    stub_people(body: { data: { people: [] } })
    assert_equal "Twenty (crm.example.com)", connect[:label]
  end

  test "refused or failed calls never expose provider bodies" do
    [ 301, 302, 401, 403, 404, 429, 500 ].each do |status|
      stub_people(body: { error: KEY }, status: status)
      error = assert_raises(Services::TwentyAdapter::Error) { connect }
      assert_not_includes error.message, KEY
    end
    assert_not_requested :get, "https://elsewhere.example.com"
  end

  test "redirects are not followed with the bearer key" do
    stub_request(:get, URL).to_return(status: 302, headers: { "Location" => "https://other.example.com/#{KEY}" })
    error = assert_raises(Services::TwentyAdapter::Error) { connect }
    assert_match "redirects", error.message
    assert_not_includes error.message, KEY
    assert_not_requested :any, /other\.example\.com/
  end

  test "unreadable and incomplete successful answers are refused" do
    [ nil, [], {}, { data: [] }, { data: { people: {} } }, { data: { people: [ nil ] } },
      { data: { people: [ {} ] } } ].each do |body|
      stub_people(body: body)
      assert_raises(Services::TwentyAdapter::Error) { connect }
    end
    stub_request(:get, URL).to_return(body: "<html>#{KEY}</html>")
    error = assert_raises(Services::TwentyAdapter::Error) { connect }
    assert_equal "Twenty returned an unreadable answer", error.message
    assert_nil error.cause
    assert_not_includes error.full_message, KEY
  end

  test "timeouts and TLS failures have safe messages and no retries" do
    [ Net::ReadTimeout.new, OpenSSL::SSL::SSLError.new(KEY), SocketError.new(KEY), EOFError.new ].each do |error|
      request = stub_request(:get, URL).to_raise(error)
      raised = assert_raises(Services::TwentyAdapter::Error) { connect }
      assert_equal "Could not reach the Twenty instance over https", raised.message
      assert_nil raised.cause
      assert_not_includes raised.full_message, KEY
      assert_requested request, times: 1
      WebMock.reset!
    end
  end

  test "rejects absent and header-unsafe credentials before networking" do
    [ "", " \n ", "bad\nkey", "bad key", "bad\u0000key", "badékey" ].each do |key|
      assert_raises(Services::TwentyAdapter::Error) { connect(key: key) }
    end
    assert_raises(Services::TwentyAdapter::Error) { connect(url: "") }
    assert_not_requested :any, /example\.com/
  end

  test "normalizes an instance or REST base and preserves safe subdirectories" do
    {
      "crm.example.com/" => "https://crm.example.com",
      "https://CRM.example.com/rest/" => "https://crm.example.com",
      "https://crm.example.com:8443/admin/rest" => "https://crm.example.com:8443/admin"
    }.each do |input, expected|
      assert_equal expected, Services::TwentyAdapter.normalize_api_url(input)
    end
    [ "http://crm.example.com", "https://user:password@crm.example.com", "https://crm.example.com?key=secret",
      "https://crm.example.com#secret", "https://crm.example.com/../private", "https://crm.example.com/%2e%2e",
      "https://" ].each do |url|
      assert_raises(Services::TwentyAdapter::Error) { Services::TwentyAdapter.normalize_api_url(url) }
    end
  end

  test "refuses private literals and mixed DNS answers using the Ghost policy" do
    [ "127.0.0.1", "10.1.2.3", "100.101.102.103", "169.254.169.254", "::1",
      "::ffff:192.168.1.1", "fd00::1", "fe80::1", "224.0.0.1" ].each do |address|
      error = assert_raises(Services::TwentyAdapter::Error) { connect(addresses: [ "93.184.216.34", address ]) }
      assert_match "not on the public internet", error.message
    end
    assert_raises(Services::TwentyAdapter::Error) { connect(addresses: []) }
    assert_raises(Services::TwentyAdapter::Error) { connect(url: "https://127.0.0.1", addresses: [ "127.0.0.1" ]) }
    assert_not_requested :any, /example\.com/
  end

  test "pins the public address and disables automatic retries" do
    stub_people
    pinned = []
    retries = []
    original_pin = Net::HTTP.instance_method(:ipaddr=)
    original_retries = Net::HTTP.instance_method(:max_retries=)
    Net::HTTP.define_method(:ipaddr=) { |address| pinned << address; original_pin.bind_call(self, address) }
    Net::HTTP.define_method(:max_retries=) { |count| retries << count; original_retries.bind_call(self, count) }

    connect

    assert_equal [ "93.184.216.34" ], pinned
    assert_equal [ 0 ], retries
  ensure
    Net::HTTP.define_method(:ipaddr=, original_pin)
    Net::HTTP.define_method(:max_retries=, original_retries)
  end

end
