module Internal
  module Comms
    # The comms connector pushes chats, messages, status changes and the
    # pairing QR here over the private network. There is no session or API
    # key: each request is HMAC-signed with the connection's own callback
    # secret (CommsSignature), as host runners sign theirs (HostRunner::
    # BaseController). The nonce is consumed only once the event is accepted.
    class EventsController < ActionController::API

      # ParamsWrapper would parse a JSON body before any callback runs.
      wrap_parameters false

      rescue_from CommsSignature::Invalid do |error|
        refuse(error.code, :unauthorized)
      end

      rescue_from CommsEvents::Refused do |error|
        refuse(error.code, error.status)
      end

      rescue_from ActiveRecord::RecordInvalid do
        refuse(:invalid_record, :unprocessable_entity)
      end

      def create
        nonce = CommsSignature.verify!(
          secret: connection.credential_payload_hash["callback_secret"],
          expected_connection_id: connection.public_id,
          method: request.request_method, path: request.path, body: raw_body, headers: request.headers
        )
        CommsEvents.receive!(connection, event, nonce:)
        head :no_content
      end

      private

      def connection
        @connection ||= begin
          found = ServiceConnection.find_by(id: connection_param.delete_prefix("svc_"))
          raise CommsSignature::Invalid.new(:unknown_connection) unless found&.credential_strategy == "connector"

          found
        end
      end

      # The body bound is enforced in front of Rails (CommsBodyLimit). Only the
      # path parameter is read here before verification.
      def connection_param
        request.path_parameters[:connection_id].to_s
      end

      def raw_body
        @raw_body ||= request.raw_post.to_s
      end

      def event
        JSON.parse(raw_body)
      rescue JSON::ParserError
        raise CommsEvents::Refused.new(:bad_json, :bad_request)
      end

      def refuse(code, status)
        Rails.logger.warn("[comms] refused #{code} connection=#{connection_param.first(40)}")
        render json: { error: code.to_s }, status:
      end

    end
  end
end
