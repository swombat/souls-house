require "test_helper"

module Api
  module V1
    module Reflexes
      class JudgmentsControllerTest < ActionDispatch::IntegrationTest

        setup do
          @user = users(:confirmed_user)
          @agent = agents(:research_assistant)
          @peer = agents(:code_reviewer)
          @headers = auth(ApiKey.generate_for(@user, name: "Reflex judgments", agent: @agent))
          @chat = @agent.account.chats.create!(title: "Reflexes", manual_responses: true, agents: [ @agent ])
          @reflex = @agent.reflexes.create!(name: "Follow-up", shape: "Does the post promise a follow-up?", reminder: "Write it down.")
        end

        test "lists the reflex's judgments newest first" do
          older = judge(score: 0.2)
          newer = judge(score: nil)
          get api_v1_reflex_judgments_url(@reflex), headers: @headers
          assert_response :ok
          assert_equal "no-store", response.headers["Cache-Control"]
          rows = response.parsed_body["judgments"]
          assert_equal [ newer.to_param, older.to_param ], rows.pluck("id")
          assert_nil rows.first["score"]
          assert_equal 0.2, rows.last["score"]
          assert_equal @reflex.to_param, rows.last["reflex_id"]
          assert_equal older.message.obfuscated_id, rows.last["message_id"]
          assert_equal @chat.to_param, rows.last["conversation_id"]
          assert_nil response.parsed_body["next_cursor"]
        end

        test "a discarded reflex's judgments stay listable" do
          judgment = judge(score: 0.9)
          delete api_v1_reflex_url(@reflex), headers: @headers
          assert_response :ok
          get api_v1_reflex_judgments_url(@reflex), headers: @headers
          assert_response :ok
          assert_equal [ judgment.to_param ], response.parsed_body["judgments"].pluck("id")
        end

        test "pages by cursor" do
          with_page_size(2) do
            judgments = Array.new(5) { judge(score: 0.1) }.reverse
            seen = []
            cursor = nil
            pages = 0
            loop do
              get api_v1_reflex_judgments_url(@reflex), params: { cursor: cursor }.compact, headers: @headers
              assert_response :ok
              page = response.parsed_body["judgments"].pluck("id")
              assert_operator page.size, :<=, 2
              seen.concat(page)
              pages += 1
              cursor = response.parsed_body["next_cursor"]
              break if cursor.nil?
            end
            assert_equal judgments.map(&:to_param), seen
            assert_equal 3, pages
          end
        end

        test "exactly one full page has no next cursor" do
          with_page_size(2) do
            2.times { judge(score: 0.1) }
            get api_v1_reflex_judgments_url(@reflex), headers: @headers
            assert_equal 2, response.parsed_body["judgments"].size
            assert_nil response.parsed_body["next_cursor"]
          end
        end

        test "a malformed cursor is unprocessable; an unknown one is not found" do
          get api_v1_reflex_judgments_url(@reflex), params: { cursor: "not a cursor!" }, headers: @headers
          assert_response :unprocessable_entity
          other = @agent.reflexes.create!(name: "Other", shape: "Q?", reminder: "R")
          foreign = Reflex::Judgment.create!(reflex: other, message: post_message, score: 0.5)
          get api_v1_reflex_judgments_url(@reflex), params: { cursor: foreign.to_param }, headers: @headers
          assert_response :not_found
        end

        test "another resident's reflex is not found" do
          theirs = @peer.reflexes.create!(name: "Theirs", shape: "Q?", reminder: "R")
          get api_v1_reflex_judgments_url(theirs), headers: @headers
          assert_response :not_found
        end

        test "human keys are forbidden" do
          judge(score: 0.5)
          headers = auth(ApiKey.generate_for(@user, name: "Human"))
          get api_v1_reflex_judgments_url(@reflex), headers: headers
          assert_response :forbidden
          assert_nil response.parsed_body["judgments"]
        end

        private

        def post_message
          @chat.messages.create!(role: "assistant", agent: @agent, content: "Post #{SecureRandom.hex(3)}")
        end

        def judge(score:)
          @reflex.judgments.create!(message: post_message, score: score)
        end

        def with_page_size(size)
          controller = Api::V1::Reflexes::JudgmentsController
          original = controller::PAGE_SIZE
          silence_warnings { controller.const_set(:PAGE_SIZE, size) }
          yield
        ensure
          silence_warnings { controller.const_set(:PAGE_SIZE, original) }
        end

        def auth(key)
          { "Authorization" => "Bearer #{key.raw_token}" }
        end

      end
    end
  end
end
