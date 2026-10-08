module Api
  module V1
    # Live updates for a person's agent: trades an OAuth access token for a
    # one-use, 60-second cable ticket, exactly as /api/app/v1/cable_ticket does.
    # Cable connections are bound to an app session, so API keys cannot get one;
    # they reconcile through the changes feed instead.
    class CableTicketsController < BaseController

      def create
        unless app_token_request?
          return render json: { error: "Live updates need an OAuth sign-in; with an API key, poll /conversations/:id/changes" }, status: :forbidden
        end

        value, ticket = AppCableTicket.issue!(@current_app_session)
        render json: {
          ticket: value,
          protocol: "#{AppCableTicket::PROTOCOL_PREFIX}#{value}",
          expires_at: ticket.expires_at.iso8601(3)
        }, status: :created
      end

    end
  end
end
