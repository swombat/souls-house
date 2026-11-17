require "test_helper"

module Api
  module V1
    class HeartbeatNotesControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @peer = agents(:code_reviewer)
        @key = ApiKey.generate_for(@user, name: "Heartbeat note", agent: @agent)
        @peer_key = ApiKey.generate_for(@user, name: "Peer heartbeat note", agent: @peer)
        @headers = { "Authorization" => "Bearer #{@key.raw_token}" }
        @path = api_v1_agent_heartbeat_note_url
      end

      test "a resident writes reads replaces and clears its own note" do
        get @path, headers: @headers
        assert_response :ok
        assert_equal "no-store", response.headers["Cache-Control"]
        assert_nil response.parsed_body["heartbeat_note"]

        assert_no_difference "Message.count" do
          put @path, params: { note: "  Follow the sparrows.  " }, headers: @headers, as: :json
        end
        assert_response :ok
        assert_equal "Follow the sparrows.", @agent.reload.heartbeat_note

        put @path, params: { note: "Something else." }, headers: @headers, as: :json
        assert_equal "Something else.", @agent.reload.heartbeat_note

        put @path, params: { note: "   " }, headers: @headers, as: :json
        assert_response :ok
        assert_nil @agent.reload.heartbeat_note

        put @path, params: { note: "Again." }, headers: @headers, as: :json
        2.times do
          delete @path, headers: @headers
          assert_response :no_content
        end
        assert_nil @agent.reload.heartbeat_note
      end

      test "a peer cannot read or change another resident's note" do
        @agent.update!(heartbeat_note: "Mine.")
        peer_headers = { "Authorization" => "Bearer #{@peer_key.raw_token}" }

        get @path, headers: peer_headers
        assert_nil response.parsed_body["heartbeat_note"]
        put @path, params: { note: "Theirs.", agent_id: @agent.id }, headers: peer_headers, as: :json
        assert_equal "Theirs.", @peer.reload.heartbeat_note, "the write lands on the caller, whatever agent_id says"
        assert_equal "Mine.", @agent.reload.heartbeat_note
        delete @path, headers: peer_headers

        assert_equal "Mine.", @agent.reload.heartbeat_note
        assert_nil @peer.reload.heartbeat_note
      end

      test "a person's key has no heartbeat note" do
        key = ApiKey.generate_for(@user, name: "Person")
        get @path, headers: { "Authorization" => "Bearer #{key.raw_token}" }
        assert_response :forbidden
      end

      test "too long or not a string is refused" do
        put @path, params: { note: "x" * (Agent::HEARTBEAT_NOTE_LIMIT + 1) }, headers: @headers, as: :json
        assert_response :unprocessable_entity
        put @path, params: { note: { a: 1 } }, headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_nil @agent.reload.heartbeat_note
      end

      test "the note is encrypted at rest and not in the agent's JSON or inspect" do
        @agent.update!(heartbeat_note: "Private line.")
        raw = Agent.connection.select_value("SELECT heartbeat_note FROM agents WHERE id = #{@agent.id}")
        assert_not_includes raw, "Private line."
        assert_not_includes @agent.as_json.to_s, "Private line."
        assert_not_includes @agent.inspect, "Private line."
      end

    end
  end
end
