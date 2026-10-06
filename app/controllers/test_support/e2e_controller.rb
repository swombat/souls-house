module TestSupport
  class E2eController < ApplicationController

    allow_unauthenticated_access
    skip_forgery_protection

    before_action :ensure_test_environment

    PASSWORD = "password123"

    def stone_fixture
      account = Account.find(params.fetch(:account_id))
      raise ActiveRecord::RecordNotFound unless account.name.start_with?("E2E ")

      chat = account.chats.create!(title: "Private stone source", model_id: "openrouter/auto")
      author = account.users.first!
      html = <<~HTML
        <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Stone comparison</title>
        <style>body{font-family:system-ui;padding:24px;background:#faf9f6;color:#252422}table{border-collapse:collapse;width:100%}td,th{padding:16px;border:1px solid #ddd}svg{max-width:100%}</style>
        </head><body><h1>Two ways to explain an idea</h1>
        <svg viewBox="0 0 500 100" role="img" aria-label="A simple comparison"><rect x="0" y="10" width="180" height="70" rx="12" fill="#b3a1cf"></rect><rect x="220" y="10" width="280" height="70" rx="12" fill="#91b6a2"></rect></svg>
        <table><thead><tr><th>Conversation</th><th>Stone</th></tr></thead><tbody><tr><td>Develop the idea together</td><td>See its shape at a glance</td></tr></tbody></table>
        <details><summary>Why both?</summary><p>The page supports the conversation, not the other way round.</p></details></body></html>
      HTML
      stone = Stone.publish!(chat: chat, title: "A first stone", html: html, author: author, public: true)
      revision = stone.latest_revision
      message = chat.messages.create!(content: "Compare these approaches.", role: "user", user: author)
      message.stone_revisions << revision
      if params[:hostile]
        # Deliberately bypass upload validation in this test-only fixture to
        # exercise the independent browser boundary against compromised storage.
        hostile = <<~HTML
          <!doctype html><h1>Hostile storage fixture</h1>
          <script>document.body.dataset.scriptRan="yes";fetch("/login");top.location="/login";</script>
          <img src="/login?stone_probe=img" onerror="document.body.dataset.eventRan='yes'">
          <style>body{background-image:url('/login?stone_probe=css')}</style>
          <iframe src="/login?stone_probe=frame"></iframe>
          <form action="/login?stone_probe=form"><button>Attempt submit</button></form>
          <a href="/login?stone_probe=top" target="_top">Attempt escape</a>
        HTML
        blob = ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(hostile), filename: "hostile.html", content_type: "text/html", identify: false)
        revision.html_attachment.update_column(:blob_id, blob.id)
      else
        stone.revise!(title: "A revised stone", html: html.sub("at a glance", "side by side"),
          author: author, public: true, base_revision_id: revision.to_param)
      end
      render json: {
        url: stone_revision_path(stone.public_token, 1),
        content_url: stone_revision_content_path(stone.public_token, 1),
        chat_url: account_chat_path(account, chat),
        cookie_name: Rails.application.config.session_options[:key]
      }
    end

    def setup
      run_id = params.fetch(:run_id)
      cleanup_run(run_id)
      # Parallel browser fixtures create several synthetic accounts each. Admission
      # policy is tested separately, after the ordinary browser project finishes.
      Setting.instance.update!(allow_agents: true, allow_chats: true, max_accounts: 1000)

      primary_user = create_user!("e2e-#{run_id}-primary@example.com")
      if params[:direct_tag_profile]
        primary_user.profile.update!(first_name: "TagReader", last_name: "Example")
      end
      secondary_user = create_user!("e2e-#{run_id}-secondary@example.com")
      admin_user = create_user!("e2e-#{run_id}-admin@example.com", site_admin: true)
      account = Account.create!(name: "E2E #{run_id} Team", account_type: :team)
      account.add_user!(primary_user, role: "owner", skip_confirmation: true) unless params[:single_account]
      account.add_user!(secondary_user, role: "member", skip_confirmation: true)
      if params[:admin_account_list]
        12.times do |index|
          Account.create!(name: "E2E #{run_id} Browse #{index.to_s.rjust(2, '0')}", account_type: :team)
        end
        account.update!(name: "E2E #{run_id} #{"LongAccountName" * 12}")
      end
      account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router") if params[:resident_credentials]
      account.whiteboards.create!(name: "E2E Whiteboard", content: "# E2E Whiteboard")

      agents = [
        create_agent!(account, "E2E Researcher", "slate"),
        create_agent!(account, "E2E Critic", "teal"),
        create_agent!(account, "E2E Paused Fork", "zinc", paused: true),
        create_agent!(account, "E2E Inactive Fork", "gray", active: false)
      ]
      agents.each { |agent| agent.update_columns(runtime: "deprecated") } if params[:deprecated]
      if params[:subagent_settings]
        account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router", openai_api_key: "test-only-openai")
        agents.first.update!(model_id: "anthropic/claude-opus-5.5", provider_auth_modes: { "anthropic" => "oauth_account" },
                             provider_connections: { "anthropic" => { "status" => "connected" } })
      end
      if params[:missing_resident_credentials]
        account.update!(use_system_ai_credentials: false)
        agents.first.update!(health_state: "healthy", birth_committed_at: Time.current,
          orientation_last_error: "Synthetic raw provider exception", orientation_last_error_at: Time.current)
      end
      if params[:costs].in?(%w[mixed unpriced])
        2.times do
          AgentRuntimeInteraction.create!(agent: agents.second, trigger_kind: "wake", started_at: Time.current,
            model: "future-unpriced-model", telemetry_schema_version: 1, usage_scope: "trigger",
            usage_complete: true, uncached_input_tokens: 1_000, cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0, output_tokens: 100)
        end
        if params[:costs] == "mixed"
          AgentRuntimeInteraction.create!(agent: agents.first, trigger_kind: "wake", started_at: Time.current,
            provider: "openai", model: "gpt-6-astra", telemetry_schema_version: 1, usage_scope: "trigger",
            usage_complete: true, uncached_input_tokens: 1_000_000, cache_creation_input_tokens: 0,
            cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000)
        end
      end
      if params[:busy_house_orientation]
        resident = agents.first
        resident.update!(model_id: HouseInference::Offering::MODEL_ID, health_state: "healthy",
          birth_committed_at: Time.current, orientation_requested_at: Time.current)
        grant = HouseInferenceGrant.create!(agent: resident, user: primary_user)
        grant.house_inference_calls.create!(month: HouseInference::Offering.month,
          model_id: resident.model_id, provider_route: "fireworks/us", charge_usd: 0.75)
      end
      if params[:resident_dashboard]
        resident = agents.first
        resident.update_columns(model_id: "anthropic/claude-opus-4.6", health_state: "healthy",
          provider_auth_modes: { "anthropic" => "oauth_account" }, provider_connections: { "anthropic" => { "status" => "connected" } },
          journal_entry_stats: { count: 27, storage_bytes: 1073741824, status: "measured", measured_at: Time.current.iso8601 },
          journal_stats_requested_at: Time.current)
        connection = account.service_connections.create!(provider: "github", connected_by_user: primary_user,
          management_scope: "personal", credential_kind: "token", credential_metadata: { "repository" => "example/dashboard" })
        resident.agent_service_accesses.create!(service_connection: connection, enabled: true)
        conversation = account.chats.create!(model_id: "openrouter/auto", title: "Dashboard activity")
        subscription = resident.telegram_subscriptions.create!(user: primary_user, telegram_chat_id: 123)
        14.times do |offset|
          conversation.messages.create!(agent: resident, role: "assistant", content: "Recorded post #{offset}", created_at: offset.days.ago)
          subscription.telegram_messages.create!(role: "assistant", text: "Recorded Telegram post #{offset}", sent_at: offset.days.ago, telegram_message_id: offset + 1) if offset.even?
          AgentRuntimeInteraction.create!(agent: resident, trigger_kind: %w[wake memory_aggregation_daily conversation][offset % 3], started_at: offset.days.ago)
        end
      end

      if params[:integrations]
        account.service_connections.create!(provider: "dropbox", connected_by_user: primary_user,
          external_subject_id: "synthetic-shared-#{run_id}", external_identity: "team@example.com",
          label: "Team files", management_scope: "account_managed", credential_kind: "oauth2",
          credential_metadata: { "credential_strategy" => "static" })
        account.service_connections.create!(provider: "github", connected_by_user: secondary_user,
          label: "member/project", management_scope: "personal", credential_kind: "token",
          credential_metadata: { "repository" => "member/project" })
      end

      render json: {
        run_id: run_id,
        password: PASSWORD,
        account_id: account.id,
        account_param: account.to_param,
        empty_account_id: primary_user.personal_account.id,
        primary_user: user_json(primary_user),
        secondary_user: user_json(secondary_user),
        admin_user: user_json(admin_user),
        agents: agents.map { |agent|
          { id: agent.to_param, name: agent.name, edit_url: edit_account_agent_path(account, agent) }
        }
      }
    end

    def assistant_message
      chat = Chat.find(params.fetch(:chat_id))
      agent = chat.agents.first || chat.account.agents.active.first
      message = chat.messages.create!(
        role: "assistant",
        agent: agent,
        content: params.fetch(:content),
        thinking: params[:thinking],
        streaming: false,
        runtime_interaction: params[:runtime_run_id] && chat.agent_runtime_interactions.find_by!(run_id: params[:runtime_run_id]),
        created_at: Time.current - params.fetch(:seconds_ago, 0).to_i.clamp(0, 3600).seconds
      )
      if params[:attach_image]
        message.attachments.attach(
          io: Rails.root.join("test/fixtures/files/test_image.png").open,
          filename: "agent-generated-image.png",
          content_type: "image/png"
        )
      end
      if params[:reply_attention_email]
        user = chat.account.users.find_by!(email_address: params[:reply_attention_email])
        chat.with_lock { ReplyExpectation.record!(message: message, user: user, score: 0.99) }
        message.update_column(:reply_attention_pending, false)
      end

      render json: { message_id: message.to_param }
    end

    # Synthetic lifecycle fixture only; never invokes a runtime or provider.
    def runtime_activity
      chat = Chat.find(params.fetch(:chat_id))
      agent = chat.agents.first!
      agent.update!(share_working_narration: false) if params[:hide_helpers]
      run = if params[:runtime_run_id]
        chat.agent_runtime_interactions.find_by!(run_id: params[:runtime_run_id])
      else
        AgentRuntimeInteraction.reserve!(agent: agent, chat: chat).tap do |interaction|
          interaction.claim_dispatch!
          interaction.activity_configuration!
        end
      end
      attempt = run.agent_runtime_attempts.first
      attempt_id = attempt&.attempt_id || SecureRandom.uuid
      seq = attempt&.last_seq || 0
      events = if params[:complete]
        chat.messages.create!(agent: agent, role: "assistant", content: "Synthetic work is complete.", runtime_interaction: run)
        [ { "seq" => seq + 1, "type" => "supervisor.finished", "data" => { "outcome" => "completed" } } ]
      elsif attempt.nil?
        [
          { "seq" => 1, "type" => "attempt.started", "data" => { "narration_capability" => params[:narration] ? "supported" : "unsupported" } },
          { "seq" => 2, "type" => "turn.started", "data" => {} },
          { "seq" => 3, "type" => "tool.started", "data" => { "category" => "command", "operation_id" => "synthetic-command", "command_preview" => "grep -n runtime app/services/agent_dispatch.rb" } }
        ]
      else
        []
      end
      if params[:narration] && attempt.nil? && !params[:complete]
        events << { "seq" => 4, "type" => "commentary.completed", "data" => { "text" => "Checking the runtime configuration." } }
      end
      next_seq = [ seq, *events.map { |event| event["seq"] } ].max
      if params[:helper_status]
        count = params.fetch(:helper_count, 1).to_i.clamp(1, 40)
        count.times do |index|
          events << { "seq" => next_seq += 1, "type" => "agent.status_changed", "data" => {
            "parent_process_id" => "synthetic-parent", "child_process_id" => "synthetic-child-#{index}",
            "agent_nickname" => "Helper #{index + 1}", "model" => "synthetic-model",
            "status" => params[:helper_status]
          } }
        end
      end
      events << { "seq" => next_seq += 1, "type" => "stream.gap", "data" => {} } if params[:stream_gap]
      RuntimeActivityIngestion.new(run, {
        "schema_version" => 1, "run_id" => run.run_id, "attempt_id" => attempt_id,
        "attempt_number" => 1, "events" => events
      }).call
      render json: { runtime_run_id: run.run_id }
    end

    # Build a deterministic conversation without involving an LLM. This gives
    # browser tests enough history to cross the 30-message pagination boundary
    # while keeping the fixture cheap and repeatable.
    def conversation_fixture
      account = Account.find(params.fetch(:account_id))
      count = params.fetch(:count, 65).to_i.clamp(0, 200)
      prefix = params.fetch(:prefix, "History message").to_s.first(80)
      user = account.users.order(:id).first!
      agents = account.agents.active.order(:id).first(params.fetch(:resident_count, 2).to_i.clamp(1, 2))

      chat = account.chats.new(
        model_id: "openrouter/auto",
        manual_responses: true,
        title: "E2E long conversation"
      )
      chat.agents = agents
      chat.save!

      messages = count.times.map do |index|
        chat.messages.create!(
          role: "user",
          user: user,
          content: "#{prefix} #{index.to_s.rjust(3, "0")}",
          created_at: Time.current - params.fetch(:seconds_ago, 0).to_i.clamp(0, 3600).seconds
        )
      end

      if params[:diagnostics]
        chat.messages.create!(role: "assistant", agent: agents.first, content: "Synthetic reply", input_tokens: 120, output_tokens: 30)
        [ [ "api_key", 500, 1, 2.hours.ago ], [ "oauth_account", 200, 0, 1.hour.ago ] ].each do |mode, status, code, time|
          AgentRuntimeInteraction.create!(agent: agents.first, chat: chat, trigger_kind: "conversation",
            session_id: "diagnostic-#{chat.id}", started_at: time, finished_at: time + 1.minute,
            provider_auth_mode: mode, transport_status: status, runtime_returncode: code,
            runtime_status: code.zero? ? "ok" : "error")
        end
      end

      render json: {
        chat_id: chat.to_param,
        message_count: messages.length,
        first_message: messages.first&.content,
        last_message: messages.last&.content
      }
    end

    # Append a burst through the normal persistence/broadcast path. A small
    # optional delay lets tests overlap broadcasts with Inertia reloads and
    # ActionCable resubscriptions instead of only testing a single quiet update.
    def append_messages
      chat = Chat.find(params.fetch(:chat_id))
      count = params.fetch(:count, 1).to_i.clamp(1, 50)
      delay_ms = params.fetch(:delay_ms, 0).to_i.clamp(0, 200)
      prefix = params.fetch(:prefix, "Live message").to_s.first(80)
      user = chat.account.users.order(:id).first!

      messages = count.times.map do |index|
        message = chat.messages.create!(
          role: "user",
          user: user,
          content: "#{prefix} #{index.to_s.rjust(3, "0")}"
        )
        sleep(delay_ms / 1000.0) if delay_ms.positive? && index < count - 1
        message
      end

      render json: {
        messages: messages.map { |message| { id: message.to_param, content: message.content } }
      }
    end

    def invitation_url
      membership = Membership.joins(:user)
        .where(users: { email_address: params.fetch(:email) })
        .order(created_at: :desc)
        .first!

      render json: {
        url: email_confirmation_path(token: membership.confirmation_token_for_url)
      }
    end

    def state
      run_id = params.fetch(:run_id)
      account = params[:account_id].present? ? Account.find(params[:account_id]) : Account.find_by!(name: "E2E #{run_id} Team")
      primary_user = User.find_by!(email_address: "e2e-#{run_id}-primary@example.com")

      render json: {
        account: {
          id: account.id,
          account_type: account.account_type,
          disabled: account.disabled?,
          active: account.active?,
          use_system_ai_credentials: account.use_system_ai_credentials?,
          members: account.memberships.includes(:user).map { |membership|
            {
              email: membership.user.email_address,
              role: membership.role,
              confirmed: membership.confirmed?
            }
          },
          chats: account.chats.includes(:agents).order(created_at: :desc).map { |chat|
            {
              id: chat.to_param,
              manual_responses: chat.manual_responses?,
              web_access: chat.web_access?,
              agent_names: chat.agents.map(&:name)
            }
          }
        },
        primary_user: {
          first_name: primary_user.first_name,
          last_name: primary_user.last_name,
          full_name: primary_user.full_name,
          timezone: primary_user.timezone,
          avatar_attached: primary_user.profile.avatar.attached?
        },
        agents: account.agents.map { |agent|
          {
            id: agent.to_param,
            name: agent.name,
            system_prompt: agent.system_prompt,
            paused: agent.paused?,
            refinement_threshold: agent.refinement_threshold,
            heartbeat_wakes_per_day: agent.heartbeat_wakes_per_day
          }
        }
      }
    end

    def cleanup
      cleanup_run(params.fetch(:run_id))
      head :no_content
    end

    private

    def ensure_test_environment
      head :not_found unless Rails.env.test?
    end

    def cleanup_run(run_id)
      users = User.where("email_address LIKE ?", "e2e-#{run_id}-%@example.com")
      member_account_ids = Membership.where(user_id: users.select(:id)).select(:account_id)
      accounts = Account.where("accounts.name LIKE ?", "E2E #{run_id}%")
        .or(Account.where(id: member_account_ids))

      accounts.includes(:agents).find_each do |account|
        account.agents.each do |agent|
          next if agent.container_name.blank?
          Agents::Sandbox.new(agent).remove!(delete_volume: true)
        end
      end

      grants = HouseInferenceGrant.where(user: users)
      HouseInferenceCall.where(house_inference_grant: grants).delete_all
      grants.delete_all
      agent_ids = accounts.joins(:agents).select("agents.id")
      Agent.where(id: agent_ids).update_all(outbound_api_key_id: nil, outbound_api_token: nil)
      ApiKey.where(agent_id: agent_ids).destroy_all
      AuditLog.where(account: accounts).or(AuditLog.where(user: users)).destroy_all
      Session.where(user: users).destroy_all
      accounts.find_each(&:destroy!)
      users.find_each(&:destroy!)
    end

    def create_user!(email, site_admin: false)
      User.create!(email_address: email, password: PASSWORD, password_confirmation: PASSWORD, is_site_admin: site_admin).tap do |user|
        user.memberships.update_all(confirmed_at: Time.current)
      end
    end

    def create_agent!(account, name, colour, active: true, paused: false)
      account.agents.create!(
        name: name,
        runtime: "external",
        system_prompt: "You are #{name}, a deterministic E2E test agent.",
        model_id: "openrouter/auto",
        colour: colour,
        icon: "Robot",
        active: active,
        paused: paused
      )
    end

    def user_json(user)
      { email: user.email_address }
    end

  end
end
