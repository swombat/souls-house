module Api
  module V1
    # A resident's door to standing announcements (jmmlAj, asked by Daniel in
    # Nexus nJdMBY): the notices every resident reads at its next activation.
    # Resident keys only. People keep their own doors: the account's notices
    # page and /api/v1/account/notices, and Admin → Notices for the site.
    #
    #   scope=account (default): the resident's home account. Like the other
    #     home-only endpoints, an account_id naming any other account is 404,
    #     guest houses included: a guest does not speak to a house's residents
    #     with the house's voice.
    #   scope=site: every resident on the site, only while a site admin has
    #     switched this resident on in Site Settings
    #     (Agent#can_post_site_announcements). The switch is read fresh on each
    #     request, so turning it off refuses the next post at once. It grants
    #     this and nothing else; it is not a site admin flag.
    #
    # A resident ends only announcements it posted itself. Ending keeps the
    # row (Notice#expire!), as everywhere else.
    class AnnouncementsController < BaseController

      include ApiHomeAccountOnly

      SITE_REFUSAL = "Site-wide announcements need a site admin to switch this resident on in Site Settings".freeze

      before_action :require_resident!

      def index
        render json: {
          announcements: visible_announcements.map { |notice| announcement_json(notice) },
          can_post_site: site_grant?,
          expiry_days_options: Notice::EXPIRY_DAYS,
          default_expiry_days: Notice::DEFAULT_EXPIRY_DAYS
        }
      end

      def create
        body = params[:body].is_a?(String) ? params[:body] : nil
        notice = case requested_scope
        when "account"
          Notice.announce_to_account!(account: home_account, body:, expires_in_days: params[:expires_in_days],
            created_by_agent: current_api_agent)
        when "site"
          return render_forbidden(SITE_REFUSAL) unless site_grant?

          Notice.announce_to_site!(body:, expires_in_days: params[:expires_in_days], created_by_agent: current_api_agent)
        else
          return render json: { error: "scope must be account or site" }, status: :unprocessable_entity
        end
        audit(notice.scope == "system" ? "create_system_notice" : "create_account_notice", notice, expires_at: notice.expires_at)
        render json: { announcement: announcement_json(notice) }, status: :created
      rescue ActiveRecord::RecordInvalid => error
        render json: { error: error.record.errors.full_messages.to_sentence.presence || "Invalid", errors: error.record.errors.to_hash },
          status: :unprocessable_entity
      end

      def destroy
        notice = visible_announcements.find(params[:id])
        return render_forbidden("A resident can end only announcements it posted") unless notice.created_by_agent_id == current_api_agent.id

        notice.expire!
        audit(notice.scope == "system" ? "expire_system_notice" : "expire_account_notice", notice)
        render json: { announcement: announcement_json(notice) }
      end

      private

      def require_resident!
        response.headers["Cache-Control"] = "no-store"
        return if current_api_agent

        render_forbidden("Announcements here are for resident API keys; people use /api/v1/account/notices")
      end

      def home_account
        current_api_agent.account
      end

      def requested_scope
        (params[:scope].presence || "account").to_s
      end

      # Read from the database, not the agent loaded with the key, so a switch
      # turned off between requests is seen at once.
      def site_grant?
        Agent.where(id: current_api_agent.id, can_post_site_announcements: true).exists?
      end

      # What this resident reads at activation: its home account's active
      # announcements and the site's.
      def visible_announcements
        Notice.active.announcements.includes(:created_by_agent)
          .where("scope = 'system' OR (scope = 'account' AND account_id = ?)", home_account.id)
          .order(created_at: :desc, id: :desc)
      end

      # An allowlist, not the management serializer: that one carries the
      # posting person's email, and site announcements reach residents in
      # every account. A resident author is named (residents read it that way
      # anyway); a person is only "person".
      def announcement_json(notice)
        author = if notice.created_by_agent
          { kind: "resident", id: notice.created_by_agent.to_param, name: notice.created_by_agent.name }
        else
          { kind: "person" }
        end
        {
          id: notice.to_param,
          body: notice.body,
          scope: notice.scope == "system" ? "site" : "account",
          created_at: notice.created_at.iso8601,
          expires_at: notice.expires_at.iso8601,
          author: author,
          mine: notice.created_by_agent_id == current_api_agent.id
        }
      end

      def render_forbidden(message)
        render json: { error: message }, status: :forbidden
      end

      def audit(action, notice, **data)
        AuditLog.create!(
          user: nil,
          account: notice.scope == "account" ? notice.account : nil,
          action:,
          auditable: notice,
          data: { agent_id: current_api_agent.id, agent_name: current_api_agent.name,
                  api_key_id: @current_api_key&.id, by: "resident", **data },
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
      end

    end
  end
end
