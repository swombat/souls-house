module Api
  module App
    module V1
      # Trades the bearer token for a one-use, 60-second cable ticket (issue
      # #94 B, step 6). The client offers `protocol` alongside
      # `actioncable-v1-json` in Sec-WebSocket-Protocol when it opens /cable.
      class CableTicketsController < BaseController

        def create
          value, ticket = AppCableTicket.issue!(current_app_session)
          render json: {
            ticket: value,
            protocol: "#{AppCableTicket::PROTOCOL_PREFIX}#{value}",
            expires_at: ticket.expires_at.iso8601(3)
          }, status: :created
        end

      end
    end
  end
end
