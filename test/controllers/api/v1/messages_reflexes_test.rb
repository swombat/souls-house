require "test_helper"

module Api
  module V1
    class MessagesReflexesTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @account = @user.personal_account
        @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Reflex room")
        @agent = agents(:research_assistant)
        @agent.update_columns(account_id: @account.id)
        @chat.agents << @agent
        @chat.update!(manual_responses: true)
        @resident = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Reflex postback", agent: @agent).raw_token}" }
        @human = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Human").raw_token}" }
        Setting.instance.update!(reflexes_scope: "all")
        @account.update!(reflexes_enabled: true)
        @reflex = @agent.reflexes.create!(name: "Follow-up", shape: "Does the post promise a follow-up?", reminder: "Write the follow-up down.", live: true)
      end

      test "a live reflex at or above threshold rides back as a cue" do
        seen = nil
        stub_decide(->(questions:, timeout:, **) { seen = timeout; reflex_scores(questions, 0.9) }) do
          post_as_resident("I'll send the link tomorrow.")
        end
        assert_response :created
        assert_equal [ { "id" => @reflex.to_param, "name" => "Follow-up", "reminder" => "Write the follow-up down." } ],
          response.parsed_body["reflexes"]
        assert_equal ReflexCheck::LIVE_TIMEOUT, seen
        message = @chat.messages.order(:id).last
        judgment = Reflex::Judgment.find_by!(reflex: @reflex, message: message)
        assert judgment.offered
        assert response.parsed_body["message"].present?
      end

      test "no reflexes, no cues and no check" do
        @reflex.discard
        stub_decide(->(questions:, **) { flunk "nothing to judge" if reflex_keys(questions).any?; questions.keys.index_with(0.0) }) do
          assert_no_enqueued_jobs(only: ReflexCheckJob) { post_as_resident("Hello") }
        end
        assert_response :created
        assert_equal [], response.parsed_body["reflexes"]
      end

      test "under the threshold there is no cue but the judgment is kept" do
        stub_decide(->(questions:, **) { reflex_scores(questions, 0.3) }) { post_as_resident("Done and merged.") }
        assert_response :created
        assert_equal [], response.parsed_body["reflexes"]
        judgment = Reflex::Judgment.find_by!(reflex: @reflex)
        assert_in_delta 0.3, judgment.score
        assert_not judgment.offered
      end

      test "a shadow reflex is judged off the post path" do
        @reflex.update!(live: false)
        stub_decide(->(questions:, **) { flunk "shadow runs in the job" if reflex_keys(questions).any?; questions.keys.index_with(0.0) }) do
          assert_enqueued_jobs 1, only: ReflexCheckJob do
            post_as_resident("I'll send the link tomorrow.")
          end
        end
        assert_response :created
        assert_equal [], response.parsed_body["reflexes"]
        assert_equal 0, Reflex::Judgment.count
      end

      test "a Jev failure never fails the post" do
        assert_difference "Message.count", 1 do
          stub_decide(->(questions:, **) { raise UtilityInference::InvalidResponse, "down" if reflex_keys(questions).any?; questions.keys.index_with(0.0) }) do
            post_as_resident("I'll send the link tomorrow.")
          end
        end
        assert_response :created
        assert_equal [], response.parsed_body["reflexes"]
        assert_nil Reflex::Judgment.find_by!(reflex: @reflex).score

        stub_decide(->(questions:, **) { raise "unexpected" if reflex_keys(questions).any?; questions.keys.index_with(0.0) }) do
          post_as_resident("Another post")
        end
        assert_response :created
        assert_equal [], response.parsed_body["reflexes"]
      end

      test "switched off, a resident post has an empty reflexes list" do
        @account.update!(reflexes_enabled: false)
        stub_decide(->(questions:, **) { flunk "switched off" if reflex_keys(questions).any?; questions.keys.index_with(0.0) }) do
          post_as_resident("I'll send the link tomorrow.")
        end
        assert_response :created
        assert_equal [], response.parsed_body["reflexes"]
      end

      test "human posts carry no reflexes key" do
        stub_decide(->(questions:, **) { flunk "humans are not judged" if reflex_keys(questions).any?; questions.keys.index_with(0.0) }) do
          post api_v1_conversation_messages_url(@chat), params: { content: "Hi" }, headers: @human, as: :json
        end
        assert_response :created
        assert_not response.parsed_body.key?("reflexes")
      end

      private

      def post_as_resident(content)
        post api_v1_conversation_messages_url(@chat), params: { content: content }, headers: @resident, as: :json
      end

      # Other decide callers on the post path (if any) keep working; only
      # the reflex question set is shaped by the test.
      def stub_decide(fn, &block)
        UtilityInference.stub(:decide, fn, &block)
      end

      def reflex_keys(questions)
        questions.keys & @agent.reflexes.map(&:to_param)
      end

      def reflex_scores(questions, score)
        questions.keys.index_with(score)
      end

    end
  end
end
