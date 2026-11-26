require "test_helper"

class Visits::ClientTest < ActiveSupport::TestCase

  include WebMock::API

  teardown { WebMock.reset! }

  PUBLIC = ->(_host) { [ "93.184.216.34" ] }

  test "InvitationLink parses invitation URLs and rejects malformed ones" do
    parsed = Visits::InvitationLink.parse("https://other.souls.house/api/v1/visit/invitations/abc12345_xyz")
    assert_equal "https://other.souls.house", parsed.origin
    assert_equal "abc12345_xyz", parsed.token

    assert_raises(Visits::InvitationLink::InvalidError) do
      Visits::InvitationLink.parse("https://other.souls.house/not-an-invite")
    end
    assert_raises(Visits::InvitationLink::InvalidError) do
      Visits::InvitationLink.parse("javascript:alert(1)")
    end
  end

  test "refuses private IP addresses before connecting" do
    [ "127.0.0.1", "10.0.0.1", "169.254.169.254", "::1", "fd00::1" ].each do |addr|
      client = Visits::Client.new(resolver: ->(_) { [ addr ] }, allow_http: false)
      error = assert_raises(Visits::Client::UnsafeOrigin) do
        client.preview_invitation(origin: "https://internal.example", token: "tok_12345678")
      end
      assert_match(/public internet/, error.message)
    end
    assert_not_requested :get, /internal\.example/
  end

  test "refuses http when allow_http is false" do
    client = Visits::Client.new(resolver: PUBLIC, allow_http: false)
    assert_raises(Visits::Client::UnsafeOrigin) do
      client.preview_invitation(origin: "http://other.souls.house", token: "tok_12345678")
    end
  end

  test "refuses redirects so visit tokens are never forwarded" do
    stub_request(:get, "https://other.souls.house/api/v1/visit/wakes")
      .to_return(status: 302, headers: { "Location" => "https://attacker.example/steal" })

    visit = Visit.new(visited_origin: "https://other.souls.house", visit_token: "vst_secret_123")
    client = Visits::Client.new(resolver: PUBLIC, allow_http: false)

    assert_raises(Visits::Client::RedirectRefused) do
      client.claim_wakes(visit)
    end
    assert_not_requested :get, /attacker\.example/
  end

  test "rejects path traversal in path segments" do
    visit = Visit.new(visited_origin: "https://other.souls.house", visit_token: "vst_secret_123")
    client = Visits::Client.new(resolver: PUBLIC, allow_http: false)

    assert_raises(Visits::Client::InvalidSegment) do
      client.conversation(visit, conversation_id: "../admin")
    end
  end

end
