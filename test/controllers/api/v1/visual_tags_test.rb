require "test_helper"

module Api
  module V1
    class VisualTagsTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:user_1)
        @account = accounts(:personal_account)
        @agent = agents(:research_assistant)
        @tag = @account.visual_tags.create!(label: "Research", icon: "MagnifyingGlass", colour: "teal")
        @room = @account.chats.create!(title: "Original", model_id: "openrouter/auto",
          manual_responses: true, agents: [ @agent ])
        @resident_headers = headers_for(ApiKey.generate_for(@user, name: "Synthetic resident", agent: @agent))
        @human_headers = headers_for(ApiKey.generate_for(@user, name: "Synthetic human", account: @account))
      end

      test "palette requires authentication and lists only requested account presentation fields" do
        get api_v1_visual_tags_path
        assert_response :unauthorized
        get api_v1_visual_tags_path, headers: @resident_headers
        assert_response :success
        assert_equal [ @tag.as_json ], response.parsed_body.fetch("visual_tags")
        get api_v1_visual_tags_path, headers: @human_headers
        assert_response :success
        assert_equal [ @tag.as_json ], response.parsed_body.fetch("visual_tags")
        get api_v1_visual_tags_path, params: { account_id: accounts(:other).to_param }, headers: @resident_headers
        assert_response :not_found
        get api_v1_visual_tags_path, params: { account_id: accounts(:team_account).to_param }, headers: @human_headers
        assert_response :not_found
      end

      test "resident selects clears and atomically renames while title-only updates stay compatible" do
        update_room({ visual_tag_id: @tag.to_param })
        assert_response :success
        assert_equal @tag.as_json, response.parsed_body.dig("conversation", "visual_tag")
        assert_equal "Original", @room.reload.title

        update_room({ visual_tag_id: nil, title: "  Renamed  " })
        assert_response :success
        assert_nil @room.reload.visual_tag
        assert_equal "Renamed", @room.title

        update_room({ title: "Title only" })
        assert_response :success
        assert_nil response.parsed_body.dig("conversation", "visual_tag")
        assert_equal "Title only", @room.reload.title
      end

      test "human account key can select a room tag" do
        update_room({ visual_tag_id: @tag.to_param }, headers: @human_headers)
        assert_response :success
        assert_equal @tag, @room.reload.visual_tag
      end

      test "malformed payloads fail explicitly without changing either metadata field" do
        @room.update!(visual_tag: @tag)
        [
          {}, { conversation: { visual_tag_id: nil } }, { visual_tag_id: nil, unknown: "ignored?" },
          { visual_tag_id: 42 }, { visual_tag_id: [] }, { visual_tag_id: {} },
          { visual_tag_id: false }, { visual_tag_id: "" }, { visual_tag_id: nil, title: nil },
          { visual_tag_id: nil, title: "\0" }, { visual_tag_id: nil, title: " " },
          { visual_tag_id: nil, title: "x" * 256 }
        ].each do |payload|
          update_room(payload)
          assert_response :unprocessable_entity, payload.inspect
          assert_equal @tag, @room.reload.visual_tag
          assert_equal "Original", @room.title
        end
      end

      test "foreign unknown and numeric database IDs cannot select tags" do
        foreign = accounts(:team_account).visual_tags.create!(label: "Care", icon: "Heart", colour: "rose")
        [ foreign.to_param, "UnknownTag", @tag.id.to_s ].each do |id|
          update_room({ visual_tag_id: id, title: "Do not rename" })
          assert_response :not_found
          assert_nil @room.reload.visual_tag
          assert_equal "Original", @room.title
        end
      end

      test "concurrent tag deletion returns a retryable conflict without renaming" do
        VisualTag.stub(:resolve_for, ->(*) { raise ActiveRecord::InvalidForeignKey }) do
          update_room({ visual_tag_id: @tag.to_param, title: "Do not rename" })
        end
        assert_response :conflict
        assert_equal "visual_tag_unavailable", response.parsed_body.fetch("code")
        assert_nil @room.reload.visual_tag
        assert_equal "Original", @room.title
      end

      test "resident cannot tag unseated rooms and foreign account keys cannot tag a room" do
        unseated = @account.chats.create!(title: "Unseated", model_id: "openrouter/auto",
          manual_responses: true, agents: [ agents(:code_reviewer) ])
        update_room({ visual_tag_id: @tag.to_param }, room: unseated)
        assert_response :not_found

        foreign_headers = headers_for(ApiKey.generate_for(@user, name: "Other account", account: accounts(:team_account)))
        update_room({ visual_tag_id: @tag.to_param }, headers: foreign_headers)
        assert_response :not_found
        update_room({ visual_tag_id: @tag.to_param }, headers: {})
        assert_response :unauthorized
      end

      test "room and list API representations include selection and reflect palette edits and deletion" do
        @room.update!(visual_tag: @tag)
        get api_v1_conversation_path(@room), headers: @resident_headers
        assert_equal @tag.as_json, response.parsed_body.dig("conversation", "visual_tag")
        get api_v1_conversations_path, headers: @resident_headers
        assert_equal @tag.as_json, response.parsed_body.fetch("conversations").first.fetch("visual_tag")

        @tag.update!(label: "Reading", icon: "BookOpen", colour: "indigo")
        get api_v1_conversation_path(@room), headers: @resident_headers
        assert_equal @tag.as_json, response.parsed_body.dig("conversation", "visual_tag")

        @tag.destroy!
        get api_v1_conversations_path, headers: @resident_headers
        assert_nil response.parsed_body.fetch("conversations").first.fetch("visual_tag")
      end

      test "guest palette and room writes use receiving account membership and stop at departure" do
        destination = accounts(:team_account)
        membership = destination.guest_memberships.create!(agent: @agent, added_by: @user)
        guest_tag = destination.visual_tags.create!(label: "Building", icon: "Wrench", colour: "blue")
        guest_room = destination.chats.create!(title: "Guest room", model_id: "openrouter/auto",
          manual_responses: true, agents: [ @agent ])

        get api_v1_visual_tags_path, params: { account_id: destination.to_param }, headers: @resident_headers
        assert_response :success
        assert_equal [ guest_tag.as_json ], response.parsed_body.fetch("visual_tags")
        update_room({ visual_tag_id: guest_tag.to_param }, room: guest_room)
        assert_response :success
        assert_equal guest_tag, guest_room.reload.visual_tag
        update_room({ visual_tag_id: @tag.to_param }, room: guest_room)
        assert_response :not_found

        membership.destroy!
        get api_v1_visual_tags_path, params: { account_id: destination.to_param }, headers: @resident_headers
        assert_response :not_found
        update_room({ visual_tag_id: nil }, room: guest_room)
        assert_response :not_found
        assert_equal guest_tag, guest_room.reload.visual_tag
      end

      private

      def headers_for(key)
        { "Authorization" => "Bearer #{key.raw_token}" }
      end

      def update_room(payload, room: @room, headers: @resident_headers)
        patch api_v1_conversation_path(room), params: payload, as: :json, headers: headers
      end

    end
  end
end
