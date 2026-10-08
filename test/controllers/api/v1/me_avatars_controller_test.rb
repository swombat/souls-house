require "test_helper"

module Api
  module V1
    class MeAvatarsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:user_1)
        @headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: 'Synthetic human', account: accounts(:personal_account)).raw_token}" }
      end

      test "upload sets the avatar, audits set_avatar and returns its url" do
        assert_difference -> { AuditLog.where(user: @user, action: "set_avatar").count }, 1 do
          put api_v1_me_avatar_path, headers: @headers, params: { avatar: fixture_file_upload("test_avatar.png", "image/png") }
        end

        assert_response :success
        assert @user.reload.avatar.attached?
        assert_match %r{\Ahttp://www.example.com/rails/active_storage/}, response.parsed_body.dig("user", "avatar_url")
      end

      test "upload without a file or with the wrong type is 422" do
        put api_v1_me_avatar_path, headers: @headers
        assert_response :unprocessable_entity
        assert_equal [ "Avatar is required" ], response.parsed_body["errors"]

        assert_no_difference -> { AuditLog.count } do
          put api_v1_me_avatar_path, headers: @headers, params: { avatar: fixture_file_upload("test.txt", "text/plain") }
        end
        assert_response :unprocessable_entity
        assert response.parsed_body["errors"].any?
        assert_not @user.reload.avatar.attached?
      end

      # Mira, #227: a non-file avatar used to reach Active Storage, where a
      # string is read as a signed blob id (InvalidSignature) and a hash as
      # attachable attributes. Only a multipart upload is accepted.
      test "a string or structured avatar is 422 and changes nothing" do
        @user.profile.update!(first_name: "Before")
        profile_updated_at = @user.profile.reload.updated_at

        [
          [ { avatar: "not-a-signed-blob" }, {} ],
          [ { avatar: { io: "x", filename: "a.png" } }, {} ],
          [ { avatar: [ "a", "b" ] }, {} ],
          [ { avatar: "not-a-signed-blob" }, { as: :json } ],
          [ { avatar: { filename: "a.png", content_type: "image/png" } }, { as: :json } ]
        ].each do |params, options|
          assert_no_difference [ -> { AuditLog.count }, -> { ActiveStorage::Attachment.count }, -> { ActiveStorage::Blob.count } ] do
            put api_v1_me_avatar_path, headers: @headers, params: params, **options
          end
          assert_response :unprocessable_entity, params.inspect
          assert_equal [ "Avatar must be an uploaded image file" ], response.parsed_body["errors"], params.inspect
        end

        assert_not @user.reload.avatar.attached?
        assert_equal profile_updated_at, @user.profile.reload.updated_at
      end

      test "delete removes the avatar and audits remove_avatar" do
        @user.avatar.attach(fixture_file_upload("test_avatar.png", "image/png"))

        perform_enqueued_jobs do
          assert_difference -> { AuditLog.where(user: @user, action: "remove_avatar").count }, 1 do
            delete api_v1_me_avatar_path, headers: @headers
          end
        end

        assert_response :success
        assert_equal({ "success" => true }, response.parsed_body)
        assert_not @user.reload.avatar.attached?
      end

      test "delete with no avatar still succeeds" do
        delete api_v1_me_avatar_path, headers: @headers
        assert_response :success
      end

    end
  end
end
