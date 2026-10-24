require "test_helper"

class Api::V1::TranscriptionGlossaryActivityTest < ActionDispatch::IntegrationTest

  include ActionCable::TestHelper
  self.use_transactional_tests = false

  test "a resident API addition invalidates only its home glossary after persistence" do
    account = Account.create!(name: "API glossary #{SecureRandom.hex(4)}", account_type: :team)
    other = Account.create!(name: "Other API glossary #{SecureRandom.hex(4)}", account_type: :team)
    agent = account.agents.create!(name: "Synthetic glossary resident", runtime: "offline")
    key = ApiKey.generate_for(users(:user_1), name: "Synthetic glossary key", agent:)
    headers = { "Authorization" => "Bearer #{key.raw_token}" }

    assert_no_broadcasts("GlossaryActivity:#{other.to_param}") do
      assert_equal [ { "action" => "refresh" } ], capture_broadcasts("GlossaryActivity:#{account.to_param}") {
        post api_v1_transcription_glossary_path, params: { term: "API vocabulary" }, as: :json, headers: headers
        assert_response :created
        assert_equal agent, account.transcription_glossary_terms.find_by!(term: "API vocabulary").created_by_agent
      }
    end
  ensure
    key&.destroy!
    account&.destroy!
    other&.destroy!
  end

end
