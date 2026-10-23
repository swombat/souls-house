require "test_helper"

module Api
  module V1
    class ReflexesControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @peer = agents(:code_reviewer)
        @headers = auth(ApiKey.generate_for(@user, name: "Reflexes", agent: @agent))
        @peer_headers = auth(ApiKey.generate_for(@user, name: "Peer reflexes", agent: @peer))
      end

      test "a resident writes, lists, switches live and discards its own reflex" do
        post api_v1_reflexes_url, params: attrs, headers: @headers, as: :json
        assert_response :created
        assert_equal "no-store", response.headers["Cache-Control"]
        body = response.parsed_body["reflex"]
        assert_equal "Follow-up", body["name"]
        assert_equal false, body["live"]
        reflex = Reflex.find(body["id"])
        assert_equal @agent, reflex.agent

        get api_v1_reflexes_url, headers: @headers
        assert_response :ok
        assert_equal [ body["id"] ], response.parsed_body["reflexes"].pluck("id")
        assert_equal false, response.parsed_body["enabled"]

        patch api_v1_reflex_url(reflex), params: { live: true }, headers: @headers, as: :json
        assert_response :ok
        assert reflex.reload.live?
        assert_equal true, response.parsed_body.dig("reflex", "live")

        delete api_v1_reflex_url(reflex), headers: @headers
        assert_response :ok
        assert reflex.reload.discarded?
        assert response.parsed_body.dig("reflex", "discarded_at").present?

        get api_v1_reflexes_url, headers: @headers
        assert_empty response.parsed_body["reflexes"]
        get api_v1_reflexes_url, params: { include_discarded: "true" }, headers: @headers
        assert_equal [ reflex.to_param ], response.parsed_body["reflexes"].pluck("id")

        # A discarded reflex is gone for update and destroy.
        patch api_v1_reflex_url(reflex), params: { live: false }, headers: @headers, as: :json
        assert_response :not_found
        delete api_v1_reflex_url(reflex), headers: @headers
        assert_response :not_found
      end

      test "index reports whether the check is switched on" do
        Setting.instance.update!(reflexes_scope: "all")
        @agent.account.update!(reflexes_enabled: true)
        get api_v1_reflexes_url, headers: @headers
        assert_equal true, response.parsed_body["enabled"]
      end

      test "create cannot set live, agent or another resident" do
        post api_v1_reflexes_url, params: attrs.merge(live: true, agent_id: @peer.id), headers: @headers, as: :json
        assert_response :created
        reflex = Reflex.find(response.parsed_body.dig("reflex", "id"))
        assert_not reflex.live?
        assert_equal @agent, reflex.agent
      end

      test "validation errors are unprocessable" do
        post api_v1_reflexes_url, params: attrs.merge(name: ""), headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_match "Name", response.parsed_body["errors"].join

        post api_v1_reflexes_url, params: attrs.merge(reminder: "r" * (Reflex::REMINDER_LENGTH + 1)), headers: @headers, as: :json
        assert_response :unprocessable_entity

        Reflex::MAX_KEPT.times { |i| @agent.reflexes.create!(name: "R#{i}", shape: "Q?", reminder: "R") }
        assert_no_difference "Reflex.count" do
          post api_v1_reflexes_url, params: attrs, headers: @headers, as: :json
        end
        assert_response :unprocessable_entity
        assert_match "at most", response.parsed_body["errors"].join
      end

      test "update changes only live; a shape change is rejected" do
        reflex = @agent.reflexes.create!(attrs)

        patch api_v1_reflex_url(reflex), params: { shape: "A new question?" }, headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_match "discard", response.parsed_body["errors"].join

        patch api_v1_reflex_url(reflex), params: { live: "yes" }, headers: @headers, as: :json
        assert_response :unprocessable_entity

        patch api_v1_reflex_url(reflex), params: { name: "Renamed", reminder: "Other" }, headers: @headers, as: :json
        assert_response :unprocessable_entity

        # Anything alongside live is refused, not quietly dropped.
        patch api_v1_reflex_url(reflex), params: { live: true, shape: "A new question?", name: "Renamed" }, headers: @headers, as: :json
        assert_response :unprocessable_entity
        reflex.reload
        assert_equal attrs[:shape], reflex.shape
        assert_equal attrs[:name], reflex.name
        assert_not reflex.live?

        # A form-encoded "true" is a boolean too.
        patch api_v1_reflex_url(reflex), params: { live: "true" }, headers: @headers
        assert_response :success
        assert reflex.reload.live?
      end

      test "a resident reaches only its own reflexes" do
        theirs = @peer.reflexes.create!(attrs)
        patch api_v1_reflex_url(theirs), params: { live: true }, headers: @headers, as: :json
        assert_response :not_found
        delete api_v1_reflex_url(theirs), headers: @headers
        assert_response :not_found
        get api_v1_reflexes_url, headers: @headers
        assert_empty response.parsed_body["reflexes"]
        assert_not theirs.reload.live?
        assert_not theirs.discarded?

        get api_v1_reflexes_url, headers: @peer_headers
        assert_equal [ theirs.to_param ], response.parsed_body["reflexes"].pluck("id")
      end

      test "human keys, including site admins, are forbidden" do
        reflex = @agent.reflexes.create!(attrs)
        [ @user, users(:site_admin_user) ].each do |user|
          headers = auth(ApiKey.generate_for(user, name: "Human reflex attempt"))
          get api_v1_reflexes_url, headers: headers
          assert_response :forbidden
          assert_equal "no-store", response.headers["Cache-Control"]
          post api_v1_reflexes_url, params: attrs, headers: headers, as: :json
          assert_response :forbidden
          patch api_v1_reflex_url(reflex), params: { live: true }, headers: headers, as: :json
          assert_response :forbidden
          delete api_v1_reflex_url(reflex), headers: headers
          assert_response :forbidden
        end
        assert_not reflex.reload.live?
        assert_not reflex.discarded?
      end

      test "missing key is rejected" do
        get api_v1_reflexes_url
        assert_response :unauthorized
      end

      private

      def attrs
        { name: "Follow-up", shape: "Does the post promise a follow-up?", reminder: "Write the follow-up down." }
      end

      def auth(key)
        { "Authorization" => "Bearer #{key.raw_token}" }
      end

    end
  end
end
