require "test_helper"

module Api
  module V1
    class TranscriptionGlossaryTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:user_1)
        @account = accounts(:personal_account)
        @agent = agents(:research_assistant)
        @resident_headers = headers_for(ApiKey.generate_for(@user, name: "Synthetic resident", agent: @agent))
        @human_headers = headers_for(ApiKey.generate_for(@user, name: "Synthetic human", account: @account))
      end

      test "requires authentication" do
        get api_v1_transcription_glossary_path
        assert_response :unauthorized
      end

      test "a person lists, adds, pins and removes terms" do
        get api_v1_transcription_glossary_path, headers: @human_headers
        assert_response :success
        assert_equal @account.to_param, response.parsed_body["account_id"]
        assert_includes response.parsed_body["terms"].map { |t| t["term"] }, "souls.house"

        post api_v1_transcription_glossary_path, params: { term: "GrantTree", pinned: true }, as: :json, headers: @human_headers
        assert_response :created
        assert_equal [ "GrantTree", true, "manual" ], response.parsed_body["term"].values_at("term", "pinned", "source")

        patch api_v1_transcription_glossary_path, params: { term: "granttree", pinned: false }, as: :json, headers: @human_headers
        assert_response :success
        assert_equal false, response.parsed_body.dig("term", "pinned")

        delete api_v1_transcription_glossary_path, params: { term: "GrantTree" }, as: :json, headers: @human_headers
        assert_response :success
        assert response.parsed_body.dig("removed", "removed_at")

        get api_v1_transcription_glossary_path, headers: @human_headers
        assert_equal [ "GrantTree" ], response.parsed_body["removed"].map { |t| t["term"] }
        refute_includes response.parsed_body["terms"].map { |t| t["term"] }, "GrantTree"
      end

      test "a resident manages its home account's glossary and is recorded as the author" do
        post api_v1_transcription_glossary_path, params: { term: "Lume" }, as: :json, headers: @resident_headers
        assert_response :created
        assert_equal @agent, @account.transcription_glossary_terms.find_by!(normalized_term: "lume").created_by_agent
        assert_equal @agent.name, response.parsed_body.dig("term", "created_by")
      end

      test "a resident can't reach another account's glossary, even by naming it" do
        other = accounts(:other)
        get api_v1_transcription_glossary_path, params: { account_id: other.to_param }, headers: @resident_headers
        assert_response :not_found
        post api_v1_transcription_glossary_path, params: { term: "Leak", account_id: other.to_param }, as: :json, headers: @resident_headers
        assert_response :not_found
        assert_empty other.transcription_glossary_terms
      end

      test "a person's key can't name an account it doesn't belong to" do
        get api_v1_transcription_glossary_path, params: { account_id: accounts(:team_account).to_param }, headers: @human_headers
        assert_response :not_found
      end

      test "term is required, must be text, and must fit Scribe's limits" do
        post api_v1_transcription_glossary_path, params: {}, as: :json, headers: @human_headers
        assert_response :unprocessable_entity
        post api_v1_transcription_glossary_path, params: { term: [ "a" ] }, as: :json, headers: @human_headers
        assert_response :unprocessable_entity
        post api_v1_transcription_glossary_path, params: { term: "a <b>" }, as: :json, headers: @human_headers
        assert_response :unprocessable_entity
        assert response.parsed_body["errors"]["term"].present?
        patch api_v1_transcription_glossary_path, params: { term: "souls.house" }, as: :json, headers: @human_headers
        assert_response :unprocessable_entity
      end

      test "pinning an unknown term is not found" do
        patch api_v1_transcription_glossary_path, params: { term: "Nope", pinned: true }, as: :json, headers: @human_headers
        assert_response :not_found
      end

      private

      def headers_for(key)
        { "Authorization" => "Bearer #{key.raw_token}" }
      end

    end
  end
end
