require "test_helper"
require "support/comms_send_helpers"

# CommsConnector.send_text against a synthetic connector: the signed command,
# and how each answer maps to a status. Only an explicit sent or failed is
# believed; everything else is unknown.
class CommsConnectorSendTest < ActiveSupport::TestCase

  include CommsSendHelpers

  setup do
    setup_comms_send
    grant_send!
    @send, = CommsSending.claim!(connection: @connection, agent: @agent, chat: @chat, text: "hello there", client_request_id: "c1")
    @secret = @connection.credential_payload_hash.fetch("callback_secret")
  end

  test "the command is signed with the connection's secret and carries the send, chat, text and chosen message id" do
    requests = []
    outcome = answer(requests, 200, { status: "sent", provider_message_id: @send.provider_message_id, sent_at: "2026-10-09T12:00:00Z" })

    assert_equal [ "sent", @send.provider_message_id, Time.iso8601("2026-10-09T12:00:00Z") ], [ outcome.status, outcome.provider_message_id, outcome.sent_at ]
    request = requests.sole
    assert_equal "/connections/#{@connection.public_id}/send_text", request.path
    CommsSignature.verify!(secret: @secret, expected_connection_id: @connection.public_id, method: "POST",
                           path: request.path, body: request.body, headers: request)
    assert_equal({ "command" => "send_text", "send_id" => @send.public_id, "message_id" => @send.provider_message_id,
                   "chat" => @chat.provider_chat_id, "text" => "hello there" }, JSON.parse(request.body))
  end

  test "an explicit failure is failed with the connector's code" do
    outcome = answer([], 422, { status: "failed", error_code: "not_on_whatsapp" })
    assert_equal [ "failed", "not_on_whatsapp" ], [ outcome.status, outcome.error_code ]
  end

  test "anything unclear is unknown: an unknown answer, sent without an id, an HTTP error, a non-JSON body" do
    assert_equal "unknown", answer([], 200, { status: "unknown", error_code: "attempted_before_restart" }).status
    assert_equal "unknown", answer([], 200, { status: "sent" }).status
    assert_equal [ "unknown", "connector_http_502" ], answer([], 502, "<html>bad gateway</html>").then { |o| [ o.status, o.error_code ] }
    assert_equal "unknown", answer([], 200, "not json").status
  end

  test "a timeout or a refused connection is unknown" do
    with_connector_url do
      Net::HTTP.stub(:start, ->(*_args, **_options) { raise Net::OpenTimeout }) do
        assert_equal [ "unknown", "connector_timeout" ], CommsConnector.send_text(@send).then { |o| [ o.status, o.error_code ] }
      end
      Net::HTTP.stub(:start, ->(*_args, **_options) { raise Errno::ECONNREFUSED }) do
        assert_equal [ "unknown", "connector_unreachable" ], CommsConnector.send_text(@send).then { |o| [ o.status, o.error_code ] }
      end
    end
  end

  test "the send waits a bounded time" do
    options = nil
    with_connector_url do
      Net::HTTP.stub(:start, ->(*_args, **kwargs) { options = kwargs; raise Net::ReadTimeout }) do
        CommsConnector.send_text(@send)
      end
    end
    assert_equal CommsConnector::SEND_READ_TIMEOUT, options[:read_timeout]
    assert_equal CommsConnector::SEND_OPEN_TIMEOUT, options[:open_timeout]
  end

  test "without a connector nothing is sent and the send is failed, not unknown" do
    outcome = CommsConnector.send_text(@send)
    assert_equal [ "failed", "connector_not_configured" ], [ outcome.status, outcome.error_code ]
  end

  private

  def answer(requests, code, body)
    with_connector_url do
      http = Object.new
      http.define_singleton_method(:request) do |request|
        requests << request
        klass = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s)
        klass.new("1.1", code.to_s, "").tap do |response|
          response.instance_variable_set(:@read, true)
          response.instance_variable_set(:@body, body.is_a?(String) ? body : JSON.generate(body))
        end
      end
      Net::HTTP.stub(:start, ->(*_args, **_options, &block) { block.call(http) }) do
        CommsConnector.send_text(@send)
      end
    end
  end

  def with_connector_url
    previous = ENV["COMMS_CONNECTOR_URL"]
    ENV["COMMS_CONNECTOR_URL"] = "http://comms.internal:8080"
    yield
  ensure
    ENV["COMMS_CONNECTOR_URL"] = previous
  end

end
