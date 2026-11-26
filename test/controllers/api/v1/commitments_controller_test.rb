require "test_helper"

module Api
  module V1
    class CommitmentsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @peer = agents(:code_reviewer)
        @account = @agent.account
        @chat = @account.chats.new(title: "Commit here", manual_responses: true)
        @chat.agents = [ @agent, @peer ]
        @chat.save!
        @headers = auth(ApiKey.generate_for(@user, name: "Commitments", agent: @agent))
        @peer_headers = auth(ApiKey.generate_for(@user, name: "Peer commitments", agent: @peer))
        @due = 2.hours.from_now.change(usec: 0)
      end

      test "a resident gives a summary with its commitment" do
        post api_v1_commitments_url, params: attrs(summary: "Rebuild receipt check"), headers: @headers, as: :json
        assert_response :created
        assert_equal [ "Rebuild receipt check", "Rebuild receipt check" ],
          response.parsed_body["commitment"].values_at("summary", "headline")

        post api_v1_commitments_url, params: attrs(text: "Another", summary: "x" * 101), headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_match(/Summary is too long/, response.parsed_body["errors"].join)
      end

      test "resident keys cannot set or change essential" do
        post api_v1_commitments_url, params: attrs.merge(essential: true), headers: @headers, as: :json
        assert_response :created
        commitment = Commitment.find(response.parsed_body.dig("commitment", "id"))
        assert_not commitment.essential?
        patch api_v1_commitment_url(commitment), params: { due_at: (@due + 1.hour).iso8601, essential: true }, headers: @headers, as: :json
        assert_response :ok
        assert_not commitment.reload.essential?
      end

      test "a resident commits, lists, reschedules and cancels its own commitment" do
        post api_v1_commitments_url, params: attrs, headers: @headers, as: :json
        assert_response :created
        assert_equal "no-store", response.headers["Cache-Control"]
        body = response.parsed_body
        assert_match(/\ACommitment \w+ scheduled for .* in this conversation\.\z/, body["receipt"])
        commitment = Commitment.find(body.dig("commitment", "id"))
        assert_equal [ @agent, @chat, "scheduled", @due ], [ commitment.agent, commitment.source_chat, commitment.status, commitment.due_at ]

        get api_v1_commitments_url, headers: @headers
        assert_equal [ commitment.to_param ], response.parsed_body["commitments"].pluck("id")

        later = (@due + 1.hour).iso8601
        patch api_v1_commitment_url(commitment), params: { due_at: later }, headers: @headers, as: :json
        assert_response :ok
        assert_equal Time.iso8601(later), commitment.reload.due_at
        assert_equal 1, commitment.reschedule_count

        delete api_v1_commitment_url(commitment), headers: @headers
        assert_response :ok
        assert_equal [ "cancelled", @agent ], [ commitment.reload.status, commitment.cancelled_by_agent ]

        delete api_v1_commitment_url(commitment), headers: @headers
        assert_response :conflict
      end

      test "a duplicate scheduled text is refused with the reason" do
        post api_v1_commitments_url, params: attrs, headers: @headers, as: :json
        assert_response :created
        announced = @chat.messages.where(role: "system").count
        post api_v1_commitments_url, params: attrs(due_at: (@due + 10.minutes).iso8601), headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_match(/same as scheduled commitment/, response.parsed_body["errors"].join)
        assert_equal announced, @chat.messages.where(role: "system").count, "a refused commitment announces nothing"
      end

      test "making a commitment posts one house line where it was made, waking nobody" do
        @account.owner.profile.update!(timezone: "Madrid")
        @account.reload
        due = Time.zone.parse("2030-11-09T11:33:00Z")
        assert_no_difference -> { AgentRuntimeInteraction.count } do
          post api_v1_commitments_url, params: attrs(summary: "Hetzner refund check 1 of 5", due_at: due.iso8601, text: "Secret details here"),
            headers: @headers, as: :json
        end
        assert_response :created
        commitment = Commitment.find(response.parsed_body.dig("commitment", "id"))
        lines = @chat.messages.where(role: "system").pluck(:content)
        # System notices render as plain text (#842): no Markdown markers, one
        # line, and a separator before the due date.
        assert_equal [ "#{@agent.name} made a commitment: Hetzner refund check 1 of 5 · due Sat 9 Nov 12:33 Europe/Madrid" ], lines
        assert_no_match(/\*|\n/, lines.first)
        assert_no_match(/Secret/, lines.join)

        patch api_v1_commitment_url(commitment), params: { due_at: (due + 1.hour).iso8601 }, headers: @headers, as: :json
        delete api_v1_commitment_url(commitment), headers: @headers
        assert_equal 1, @chat.messages.where(role: "system").count, "rescheduling and cancelling post nothing"

        @account.rooms.create!(name: "Ops")
        post api_v1_commitments_url, params: attrs(text: "Elsewhere", destination: "new_conversation", room: "Ops", due_at: due.iso8601),
          headers: @headers, as: :json
        assert_response :created
        assert_match(/· will open a new conversation in Ops\z/, @chat.messages.where(role: "system").order(:id).last.content)
      end

      test "due_at needs a zone and the future" do
        post api_v1_commitments_url, params: attrs(due_at: "2026-11-03T03:00:00"), headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_match(/ISO 8601 with a zone/, response.parsed_body["errors"].join)
        post api_v1_commitments_url, params: attrs(due_at: 1.hour.ago.iso8601), headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_match(/future/, response.parsed_body["errors"].join)
      end

      test "a new conversation goes to the named room, or the account's resident room" do
        room = @account.rooms.create!(name: "Ops")
        post api_v1_commitments_url, params: attrs(destination: "new_conversation", room: "Ops"), headers: @headers, as: :json
        assert_response :created
        assert_equal room, Commitment.find(response.parsed_body.dig("commitment", "id")).room
        assert_match(/a new conversation in Ops/, response.parsed_body["receipt"])

        default = @account.rooms.create!(name: "Residents")
        @account.update!(resident_room: default)
        post api_v1_commitments_url, params: attrs(text: "Another", destination: "new_conversation"), headers: @headers, as: :json
        assert_response :created
        assert_equal default, Commitment.find(response.parsed_body.dig("commitment", "id")).room
      end

      test "a source message must be in the conversation" do
        elsewhere = @account.chats.new(title: "Elsewhere", manual_responses: true)
        elsewhere.agents = [ @agent ]
        elsewhere.save!
        message = elsewhere.messages.create!(role: "user", user: @user, content: "hi", suppress_automatic_dispatch: true)
        post api_v1_commitments_url, params: attrs(source_message_id: message.to_param), headers: @headers, as: :json
        assert_response :not_found
      end

      test "a resident cannot commit from a conversation it is not in" do
        other = @account.chats.new(title: "Not mine", manual_responses: true)
        other.agents = [ @peer ]
        other.save!
        post api_v1_commitments_url, params: attrs(conversation_id: other.to_param), headers: @headers, as: :json
        assert_response :forbidden
      end

      test "a resident sees and manages only its own commitments" do
        post api_v1_commitments_url, params: attrs, headers: @headers, as: :json
        id = response.parsed_body.dig("commitment", "id")
        get api_v1_commitments_url, headers: @peer_headers
        assert_empty response.parsed_body["commitments"]
        delete api_v1_commitment_url(id), headers: @peer_headers
        assert_response :not_found
        patch api_v1_commitment_url(id), params: { due_at: (@due + 1.hour).iso8601 }, headers: @peer_headers, as: :json
        assert_response :not_found
      end

      test "a person's key cannot use commitments" do
        headers = auth(ApiKey.generate_for(@user, name: "Human"))
        get api_v1_commitments_url, headers: headers
        assert_response :forbidden
      end

      test "a resident makes a recurring commitment, fixed or a range, and the receipt says so" do
        post api_v1_commitments_url, params: attrs(recur_min_minutes: 60, recur_max_minutes: 90), headers: @headers, as: :json
        assert_response :created
        body = response.parsed_body
        assert_equal({ "min_minutes" => 60, "max_minutes" => 90, "max_occurrences" => nil, "phrase" => "every 60–90 minutes" },
                     body.dig("commitment", "recurrence"))
        assert_match(/recurs every 60–90 minutes after each delivery until you cancel it/, body["receipt"])
        assert_match(/ · recurs every 60–90 minutes\z/, @chat.messages.where(role: "system").last.content)

        post api_v1_commitments_url, params: attrs(text: "Fixed", recur_every_minutes: "45"), headers: @headers, as: :json
        assert_response :created
        assert_equal [ 45, 45 ], Commitment.find(response.parsed_body.dig("commitment", "id")).values_at(:recur_min_minutes, :recur_max_minutes)

        post api_v1_commitments_url, params: attrs(text: "Capped", recur_every_minutes: 30, recur_max_occurrences: "6"), headers: @headers, as: :json
        assert_response :created
        assert_equal 6, response.parsed_body.dig("commitment", "recurrence", "max_occurrences")
      end

      test "a malformed recurrence is refused with a reason" do
        [
          [ { recur_min_minutes: 60 }, /go together/ ],
          [ { recur_every_minutes: 30, recur_min_minutes: 20, recur_max_minutes: 40 }, /not both/ ],
          [ { recur_every_minutes: "an hour" }, /whole numbers/ ],
          [ { recur_every_minutes: 1 }, /between 5 minutes/ ],
          [ { recur_min_minutes: 90, recur_max_minutes: 60 }, /minimum cannot be more/ ],
          [ { recur_max_occurrences: 3 }, /needs a recurrence/ ],
          [ { recur_every_minutes: 30, recur_max_occurrences: "six" }, /whole number/ ],
          [ { recur_every_minutes: 30, recur_max_occurrences: 0 }, /between 1 and/ ]
        ].each_with_index do |(recurrence, message), i|
          post api_v1_commitments_url, params: attrs(text: "Bad #{i}", **recurrence), headers: @headers, as: :json
          assert_response :unprocessable_entity
          assert_match message, response.parsed_body["errors"].join
        end
      end

      test "deleting a delivered occurrence ends the series" do
        post api_v1_commitments_url, params: attrs(recur_every_minutes: 30), headers: @headers, as: :json
        first = Commitment.find(response.parsed_body.dig("commitment", "id"))
        upcoming = first.update_columns(status: "activated", wake_state: "delivered") &&
          Commitment.create!(agent: @agent, source_chat: @chat, text: first.text, due_at: @due + 30.minutes,
                             recur_min_minutes: 30, recur_max_minutes: 30, series_root: first, previous_commitment: first, occurrence: 2)
        delete api_v1_commitment_url(first), headers: @headers
        assert_response :ok
        assert response.parsed_body["series_ended"]
        assert upcoming.reload.cancelled?
      end

      private

      def attrs(**overrides)
        { conversation_id: @chat.to_param, text: "Check the rebuild receipt", due_at: @due.iso8601 }.merge(overrides)
      end

      def auth(key)
        { "Authorization" => "Bearer #{key.raw_token}" }
      end

    end
  end
end
