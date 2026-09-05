module TestSupport
  class E2eController < ApplicationController

    allow_unauthenticated_access
    skip_forgery_protection

    before_action :ensure_test_environment

    PASSWORD = "password123"

    def setup
      run_id = params.fetch(:run_id)
      cleanup_run(run_id)
      Setting.instance.update!(allow_agents: true, allow_chats: true)

      primary_user = create_user!("e2e-#{run_id}-primary@example.com")
      secondary_user = create_user!("e2e-#{run_id}-secondary@example.com")
      admin_user = create_user!("e2e-#{run_id}-admin@example.com", site_admin: true)
      account = Account.create!(name: "E2E #{run_id} Team", account_type: :team)
      account.add_user!(primary_user, role: "owner", skip_confirmation: true)
      account.add_user!(secondary_user, role: "member", skip_confirmation: true)
      account.whiteboards.create!(name: "E2E Whiteboard", content: "# E2E Whiteboard")

      agents = [
        create_agent!(account, "E2E Researcher", "slate"),
        create_agent!(account, "E2E Critic", "teal"),
        create_agent!(account, "E2E Paused Fork", "zinc", paused: true),
        create_agent!(account, "E2E Inactive Fork", "gray", active: false)
      ]
      agents.each { |agent| agent.update_columns(runtime: "deprecated") } if params[:deprecated]

      render json: {
        run_id: run_id,
        password: PASSWORD,
        account_id: account.id,
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
        streaming: false
      )
      if params[:attach_image]
        message.attachments.attach(
          io: Rails.root.join("test/fixtures/files/test_image.png").open,
          filename: "agent-generated-image.png",
          content_type: "image/png"
        )
      end

      render json: { message_id: message.to_param }
    end

    # Build a deterministic conversation without involving an LLM. This gives
    # browser tests enough history to cross the 30-message pagination boundary
    # while keeping the fixture cheap and repeatable.
    def conversation_fixture
      account = Account.find(params.fetch(:account_id))
      count = params.fetch(:count, 65).to_i.clamp(1, 200)
      prefix = params.fetch(:prefix, "History message").to_s.first(80)
      user = account.users.order(:id).first!
      agents = account.agents.active.order(:id).first(2)

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
          content: "#{prefix} #{index.to_s.rjust(3, "0")}"
        )
      end

      render json: {
        chat_id: chat.to_param,
        message_count: messages.length,
        first_message: messages.first.content,
        last_message: messages.last.content
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
